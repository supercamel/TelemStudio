local GLib = import("GLib")
local Gio = import("Gio")
local Soup = import("Soup")

function trim_text(s) {
    local a = 0
    local b = s.len()
    while (a < b) {
        local c = s.slice(a, a + 1)
        if (c != " " && c != "\t" && c != "\n" && c != "\r") break
        a += 1
    }
    while (b > a) {
        local c = s.slice(b - 1, b)
        if (c != " " && c != "\t" && c != "\n" && c != "\r") break
        b -= 1
    }
    return s.slice(a, b)
}

function split_text(s, sep) {
    local out = []
    local start = 0
    while (true) {
        local p = s.find(sep, start)
        if (p == null) {
            out.push(s.slice(start))
            return out
        }
        out.push(s.slice(start, p))
        start = p + sep.len()
    }
}

function coerce_scalar(v) {
    if (typeof v != "string") return v
    local s = trim_text(v)
    if (s == "true") return true
    if (s == "false") return false
    try {
        if (s.find(".") != null) return s.tofloat()
        return s.tointeger()
    } catch (_) {}
    return v
}

function flatten_json(prefix, value, out) {
    if (typeof value == "table") {
        foreach (k, v in value) {
            local key = prefix.len() > 0 ? (prefix + "." + k) : k
            flatten_json(key, v, out)
        }
        return
    }
    if (typeof value == "array") {
        for (local i = 0; i < value.len(); i += 1) {
            local key = prefix.len() > 0 ? (prefix + "." + i) : ("" + i)
            flatten_json(key, value[i], out)
        }
        return
    }
    if (prefix.len() > 0) out[prefix] <- value
}

function parse_key_value_text(text, prefix = "") {
    local out = {}
    local normal = text
    foreach (sep in ["\r\n", "\n", ";", ","]) {
        local pieces = split_text(normal, sep)
        if (pieces.len() > 1) {
            foreach (piece in pieces) {
                local p = parse_key_value_text(piece, prefix)
                foreach (k, v in p) out[k] <- v
            }
            return out
        }
    }

    local line = trim_text(normal)
    if (line.len() == 0) return out
    local eq = line.find("=")
    if (eq == null) eq = line.find(":")
    if (eq != null) {
        local key = trim_text(line.slice(0, eq))
        local val = trim_text(line.slice(eq + 1))
        if (key.len() > 0) out[(prefix.len() > 0 ? prefix + "." + key : key)] <- coerce_scalar(val)
    } else if (prefix.len() > 0) {
        out[prefix] <- coerce_scalar(line)
    }
    return out
}

function parse_payload(text, prefix = "") {
    local s = trim_text(text)
    local out = {}
    if (s.len() == 0) return out

    local first = s.slice(0, 1)
    if (first == "{" || first == "[") {
        try {
            flatten_json(prefix, sqgi.json.parse(s), out)
            return out
        } catch (_) {}
    }
    return parse_key_value_text(s, prefix)
}

function mk_addr(ip_str, port) {
    return sqgi.new_object(Gio.InetSocketAddress, {
        "address": Gio.InetAddress.new_from_string(ip_str),
        "port": port,
    })
}

function send_text(msg, status, text) {
    msg.set_status(status, null)
    msg.set_response("text/plain; charset=utf-8", Soup.MemoryUse.copy, text)
}

function send_json(msg, status, value) {
    msg.set_status(status, null)
    msg.set_response("application/json; charset=utf-8",
        Soup.MemoryUse.copy, sqgi.json.stringify(value))
}

async function fetch_http_source(src, store) {
    local session = Soup.Session.new()
    local msg = Soup.Message.new("GET", src.url)
    msg.get_request_headers().append("Accept", "application/json, text/plain;q=0.9, */*;q=0.5")
    msg.get_request_headers().append("User-Agent", "TelemStudio/0.1")
    local bytes = await session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT)
    local status = msg.get_status()
    if (status < 200 || status >= 300) throw "HTTP status " + status
    store.merge(parse_payload(bytes.get_data(), src.prefix))
    src.last_status = "HTTP " + status
}

async function fetch_tcp_source(src, store) {
    local client = Gio.SocketClient.new()
    local conn = await client.connect_to_host_async(src.host, src.port)
    if (src.payload.len() > 0) {
        await conn.get_output_stream().write_bytes_async(GLib.Bytes.new(src.payload), GLib.PRIORITY_DEFAULT)
    }
    local got = await conn.get_input_stream().read_bytes_async(65536, GLib.PRIORITY_DEFAULT)
    store.merge(parse_payload(got.get_data(), src.prefix))
    conn.close(null)
    src.last_status = format("TCP %s:%d", src.host, src.port)
}

class DataSourceConfig {
    id = null
    name = null
    kind = "http"
    enabled = true
    interval_ms = 500
    url = "http://127.0.0.1:8080/telemetry.json"
    host = "127.0.0.1"
    port = 9000
    payload = ""
    prefix = ""
    last_poll_us = 0
    in_flight = false
    socket = null
    server = null
    last_status = "idle"
    last_error = ""

    constructor(id, name, kind, enabled = false) {
        this.id = id
        this.name = name
        this.kind = kind
        this.enabled = enabled
    }
}

class DataSourceManager {
    store = null
    sources = null
    running = false
    start_us = 0

    constructor(store) {
        this.store = store
        this.sources = []
        local http = DataSourceConfig("http", "HTTP JSON poll", "http", false)
        http.interval_ms = 1000
        this.sources.push(http)
        local http_post = DataSourceConfig("http_post", "HTTP JSON POST endpoint", "http_post", false)
        http_post.url = "/telemetry"
        http_post.interval_ms = 0
        http_post.port = 9001
        this.sources.push(http_post)
        local tcp = DataSourceConfig("tcp", "TCP text/json poll", "tcp", false)
        tcp.interval_ms = 1000
        tcp.payload = "telemetry\n"
        this.sources.push(tcp)
        local udp = DataSourceConfig("udp", "UDP text/json listener", "udp", false)
        udp.interval_ms = 0
        udp.host = "0.0.0.0"
        this.sources.push(udp)
    }

    function start() {
        this.running = true
        this.start_us = GLib.get_monotonic_time()
        foreach (src in this.sources) {
            if (src.enabled && src.kind == "udp") this.ensure_udp(src)
            if (src.enabled && src.kind == "http_post") this.ensure_http_post(src)
        }
    }

    function stop() {
        this.running = false
        foreach (src in this.sources) {
            if (src.socket != null) {
                try { src.socket.close(null) } catch (_) {}
                src.socket = null
            }
            if (src.server != null) {
                try { src.server.disconnect() } catch (_) {}
                src.server = null
            }
            src.in_flight = false
        }
    }

    function selected(index) {
        if (index < 0 || index >= this.sources.len()) return null
        return this.sources[index]
    }

    function ensure_udp(src) {
        if (src.socket != null) return
        try {
            local s = Gio.Socket.new(Gio.SocketFamily.ipv4, Gio.SocketType.datagram, Gio.SocketProtocol.udp)
            s.set_blocking(false)
            s.bind(mk_addr(src.host, src.port), true)
            src.socket = s
            src.last_status = format("listening UDP %s:%d", src.host, src.port)
            sqgi.socket_add_watch(s, GLib.IOCondition.in, function(sock, cond) {
                if (!this.running || !src.enabled || src.socket == null) return false
                try {
                    local r = sock.receive_bytes_from(65536, 0, null)
                    this.store.merge(parse_payload(r[0].get_data().tostring(), src.prefix))
                    src.last_status = format("UDP packet from %s:%d",
                        r[1].get_address().to_string(), r[1].get_port())
                    src.last_error = ""
                } catch (e) {
                    src.last_error = e.tostring()
                }
                return true
            }.bindenv(this))
        } catch (e) {
            src.last_error = e.tostring()
            src.socket = null
        }
    }

    function ensure_http_post(src) {
        if (src.server != null) return
        try {
            local server = sqgi.new_object(Soup.Server, {})
            local path = src.url.len() > 0 ? src.url : "/telemetry"
            if (path.slice(0, 1) != "/") path = "/" + path

            server.add_handler(path, function(_s, msg, _p, _q) {
                if (msg.get_method() != "POST") {
                    msg.get_response_headers().append("Allow", "POST")
                    send_json(msg, 405, { error = "POST required" })
                    return
                }

                local text = msg.get_request_body().flatten().get_data()
                try {
                    local update = parse_payload(text, src.prefix)
                    if (update.len() == 0) {
                        send_json(msg, 400, { error = "empty telemetry payload" })
                        return
                    }
                    this.store.merge(update)
                    src.last_status = format("HTTP POST %s:%d%s", src.host, src.port, path)
                    src.last_error = ""
                    send_json(msg, 200, { ok = true, fields = update.len() })
                } catch (e) {
                    src.last_error = e.tostring()
                    send_json(msg, 400, { error = "invalid telemetry payload", detail = e.tostring() })
                }
            }.bindenv(this))

            if (src.host == "0.0.0.0" || src.host == "::") {
                server.listen_all(src.port, Soup.ServerListenOptions.ipv4_only)
            } else if (src.host == "127.0.0.1" || src.host == "localhost") {
                server.listen_local(src.port, Soup.ServerListenOptions.ipv4_only)
            } else {
                server.listen(mk_addr(src.host, src.port), Soup.ServerListenOptions.ipv4_only)
            }

            src.server = server
            src.last_status = format("listening HTTP POST %s:%d%s", src.host, src.port, path)
            src.last_error = ""
        } catch (e) {
            src.last_error = e.tostring()
            if (src.server != null) {
                try { src.server.disconnect() } catch (_) {}
            }
            src.server = null
        }
    }

    function tick() {
        if (!this.running) return false
        local now = GLib.get_monotonic_time()
        foreach (src in this.sources) {
            if (!src.enabled) continue
            if (src.kind == "udp") {
                this.ensure_udp(src)
            } else if (src.kind == "http_post") {
                this.ensure_http_post(src)
            } else if (!src.in_flight && src.interval_ms > 0 &&
                       (now - src.last_poll_us) >= src.interval_ms * 1000) {
                src.last_poll_us = now
                src.in_flight = true
                local ref = src
                local task = ref.kind == "http"
                    ? fetch_http_source(ref, this.store)
                    : fetch_tcp_source(ref, this.store)
                task.then(function(_) {
                    ref.in_flight = false
                    ref.last_error = ""
                }).catch(function(e) {
                    ref.in_flight = false
                    ref.last_error = e.tostring()
                })
            }
        }
        return true
    }

    function summary() {
        local parts = []
        foreach (src in this.sources) {
            if (!src.enabled) continue
            parts.push(src.name + ": " + (src.last_error.len() > 0 ? src.last_error : src.last_status))
        }
        return parts.len() > 0 ? parts.tostring() : "No data sources enabled"
    }
}

return {
    DataSourceConfig = DataSourceConfig,
    DataSourceManager = DataSourceManager,
    parse_payload = parse_payload
}
