local GLib = import("GLib")

local D = import("lib/overlay_document.nut")
local P = import("lib/pipeline_controller.nut")

local PROJECT_VERSION = 1

function table_get(t, key, fallback) {
    return typeof t == "table" && key in t ? t[key] : fallback
}

function apply_fields(target, src, fields) {
    if (typeof src != "table") return
    foreach (name in fields) {
        if (name in src) target[name] = src[name]
    }
}

function item_to_table(item) {
    return {
        id = item.id,
        type = item.type,
        name = item.name,
        enabled = item.enabled,
        x = item.x,
        y = item.y,
        width = item.width,
        height = item.height,
        scale = item.scale,
        rotation = item.rotation,
        opacity = item.opacity,
        text = item.text,
        field = item.field,
        prefix = item.prefix,
        suffix = item.suffix,
        decimals = item.decimals,
        align = item.align,
        font_size = item.font_size,
        font_family = item.font_family,
        bold = item.bold,
        italic = item.italic,
        padding = item.padding,
        radius = item.radius,
        text_color = item.text_color,
        fill = item.fill,
        stroke = item.stroke,
        shadow = item.shadow,
        fit = item.fit,
        path = item.path,
    }
}

function item_from_table(t) {
    local item = D.OverlayItem(table_get(t, "id", 0), table_get(t, "type", "text"), table_get(t, "name", "Overlay"))
    apply_fields(item, t, [
        "enabled", "x", "y", "width", "height", "scale", "rotation", "opacity",
        "text", "field", "prefix", "suffix", "decimals", "align", "font_size",
        "font_family", "bold", "italic", "padding", "radius", "text_color",
        "fill", "stroke", "shadow", "fit", "path"
    ])
    return item
}

function document_to_table(document) {
    local items = []
    foreach (item in document.items) items.push(item_to_table(item))
    return {
        video_width = document.video_width,
        video_height = document.video_height,
        selected_id = document.selected_id,
        next_id = document.next_id,
        items = items,
    }
}

function document_from_table(t) {
    local document = D.OverlayDocument()
    document.items = []
    document.video_width = table_get(t, "video_width", document.video_width)
    document.video_height = table_get(t, "video_height", document.video_height)
    document.selected_id = table_get(t, "selected_id", null)
    document.next_id = table_get(t, "next_id", 1)

    local max_id = 0
    local raw_items = table_get(t, "items", [])
    if (typeof raw_items == "array") {
        foreach (raw in raw_items) {
            local item = item_from_table(raw)
            document.items.push(item)
            if (item.id > max_id) max_id = item.id
        }
    }
    if (document.items.len() > 0 && document.selected_id == null) document.selected_id = document.items[0].id
    if (document.next_id <= max_id) document.next_id = max_id + 1
    return document
}

function source_to_table(source) {
    return {
        kind = source.kind,
        device = source.device,
        uri = source.uri,
        custom_source = source.custom_source,
        test_pattern = source.test_pattern,
        width = source.width,
        height = source.height,
        fps = source.fps,
        crop_top = source.crop_top,
        crop_bottom = source.crop_bottom,
        crop_left = source.crop_left,
        crop_right = source.crop_right,
        flip = source.flip,
        deinterlace = source.deinterlace,
        loop_input = source.loop_input,
        output_kind = source.output_kind,
        output_path = source.output_path,
        output_host = source.output_host,
        output_port = source.output_port,
        stream_uri = source.stream_uri,
        youtube_server_url = source.youtube_server_url,
        facebook_server_url = source.facebook_server_url,
        container = source.container,
        video_encoder = source.video_encoder,
        bitrate_kbps = source.bitrate_kbps,
        speed_preset = source.speed_preset,
        custom_sink = source.custom_sink,
    }
}

function source_from_table(t) {
    local source = P.VideoSourceConfig()
    apply_fields(source, t, [
        "kind", "device", "uri", "custom_source", "test_pattern", "width", "height",
        "fps", "crop_top", "crop_bottom", "crop_left", "crop_right", "flip",
        "deinterlace", "loop_input", "output_kind", "output_path", "output_host",
        "output_port", "stream_uri", "youtube_server_url", "facebook_server_url",
        "container", "video_encoder",
        "bitrate_kbps", "speed_preset", "custom_sink"
    ])
    return source
}

function data_source_to_table(src) {
    return {
        id = src.id,
        name = src.name,
        kind = src.kind,
        enabled = src.enabled,
        interval_ms = src.interval_ms,
        url = src.url,
        host = src.host,
        port = src.port,
        payload = src.payload,
        prefix = src.prefix,
    }
}

function data_sources_to_table(manager) {
    local out = []
    foreach (src in manager.sources) out.push(data_source_to_table(src))
    return out
}

function apply_data_sources(manager, raw_sources) {
    if (typeof raw_sources != "array") return
    foreach (raw in raw_sources) {
        if (typeof raw != "table") continue
        local id = table_get(raw, "id", "")
        local kind = table_get(raw, "kind", "")
        foreach (src in manager.sources) {
            if ((id.len() > 0 && src.id == id) || (kind.len() > 0 && src.kind == kind)) {
                apply_fields(src, raw, [
                    "enabled", "interval_ms", "url", "host", "port", "payload", "prefix"
                ])
                break
            }
        }
    }
}

function make_project(document, source, data_sources) {
    return {
        format = "TelemStudio project",
        version = PROJECT_VERSION,
        document = document_to_table(document),
        source = source_to_table(source),
        data_sources = data_sources_to_table(data_sources),
    }
}

function save_project(path, document, source, data_sources) {
    local text = sqgi.json.stringify(make_project(document, source, data_sources))
    GLib.file_set_contents(path, text, -1)
}

function load_project(path) {
    local text = GLib.file_get_contents(path)
    local project = sqgi.json.parse(text)
    return {
        document = document_from_table(table_get(project, "document", {})),
        source = source_from_table(table_get(project, "source", {})),
        data_sources = table_get(project, "data_sources", []),
    }
}

return {
    PROJECT_VERSION = PROJECT_VERSION,
    make_project = make_project,
    save_project = save_project,
    load_project = load_project,
    apply_data_sources = apply_data_sources,
}
