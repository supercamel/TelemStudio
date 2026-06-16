class OverlayItem {
    id = null
    type = null
    name = null
    enabled = true
    x = 40.0
    y = 40.0
    width = 360.0
    height = 120.0
    scale = 1.0
    rotation = 0.0
    opacity = 0.92
    text = ""
    field = ""
    prefix = ""
    suffix = ""
    decimals = 1
    align = "left"
    font_size = 28.0
    font_family = "Sans"
    bold = true
    italic = false
    padding = 18.0
    radius = 8.0
    text_color = null
    fill = null
    stroke = null
    shadow = true
    fit = "contain"
    path = ""

    constructor(id, type, name) {
        this.id = id
        this.type = type
        this.name = name
        this.text_color = [1.0, 1.0, 1.0, 0.96]
        this.fill = [0.04, 0.05, 0.06, 0.72]
        this.stroke = [0.08, 0.62, 0.88, 0.95]
    }
}

function max_value(a, b) {
    return a > b ? a : b
}

class OverlayDocument {
    items = null
    selected_id = null
    next_id = 1
    video_width = 1280.0
    video_height = 720.0

    constructor() {
        this.items = []
        this.add_scorebug()
        this.add_telemetry_text("Speed", "speed")
        this.add_shape()
        this.selected_id = this.items[0].id
    }

    function add_item(type, name) {
        local item = OverlayItem(this.next_id, type, name)
        this.next_id += 1
        this.items.push(item)
        this.selected_id = item.id
        return item
    }

    function add_text() {
        local item = this.add_item("text", "Text")
        item.text = "Custom overlay"
        item.width = 340.0
        item.height = 70.0
        item.font_size = 32.0
        return item
    }

    function add_telemetry_text(label, field) {
        local item = this.add_item("telemetry", label + " telemetry")
        item.text = label
        item.field = field
        item.suffix = field == "speed" ? " km/h" : ""
        item.x = 44.0
        item.y = 190.0 + (this.items.len() * 24.0)
        item.width = 360.0
        item.height = 78.0
        item.font_size = 26.0
        return item
    }

    function add_scorebug() {
        local item = this.add_item("scorebug", "Score bug")
        item.x = 36.0
        item.y = 32.0
        item.width = 520.0
        item.height = 112.0
        item.font_size = 30.0
        item.padding = 24.0
        return item
    }

    function add_shape() {
        local item = this.add_item("shape", "Panel graphic")
        item.x = 860.0
        item.y = 520.0
        item.width = 320.0
        item.height = 96.0
        item.opacity = 0.55
        item.text = ""
        return item
    }

    function add_image_placeholder() {
        local item = this.add_item("image", "Graphic image")
        item.x = 880.0
        item.y = 82.0
        item.width = 260.0
        item.height = 160.0
        item.text = "Image/PNG asset"
        item.path = ""
        item.fit = "contain"
        return item
    }

    function add_timer() {
        local item = this.add_item("timer", "Timer")
        item.x = 920.0
        item.y = 40.0
        item.width = 230.0
        item.height = 78.0
        item.text = "Clock"
        item.font_size = 30.0
        item.align = "center"
        return item
    }

    function selected() {
        foreach (item in this.items) {
            if (item.id == this.selected_id) return item
        }
        return null
    }

    function select_id(id) {
        this.selected_id = id
    }

    function bring_forward() {
        for (local i = 0; i < this.items.len() - 1; i += 1) {
            if (this.items[i].id == this.selected_id) {
                local item = this.items[i]
                this.items.remove(i)
                this.items.insert(i + 1, item)
                return
            }
        }
    }

    function send_backward() {
        for (local i = 1; i < this.items.len(); i += 1) {
            if (this.items[i].id == this.selected_id) {
                local item = this.items[i]
                this.items.remove(i)
                this.items.insert(i - 1, item)
                return
            }
        }
    }

    function delete_selected() {
        for (local i = 0; i < this.items.len(); i += 1) {
            if (this.items[i].id == this.selected_id) {
                this.items.remove(i)
                this.selected_id = this.items.len() > 0 ? this.items[0].id : null
                return
            }
        }
    }

    function item_center(item) {
        return [
            item.x + item.width / 2.0,
            item.y + item.height / 2.0
        ]
    }

    function item_local_point(item, x, y) {
        local c = this.item_center(item)
        local dx = x - c[0]
        local dy = y - c[1]
        local r = -item.rotation * 3.14159265359 / 180.0
        local co = cos(r)
        local si = sin(r)
        local sc = max_value(item.scale, 0.001)
        return [
            c[0] + ((dx * co) - (dy * si)) / sc,
            c[1] + ((dx * si) + (dy * co)) / sc
        ]
    }

    function local_to_world(item, x, y) {
        local c = this.item_center(item)
        local dx = (x - c[0]) * item.scale
        local dy = (y - c[1]) * item.scale
        local r = item.rotation * 3.14159265359 / 180.0
        local co = cos(r)
        local si = sin(r)
        return [
            c[0] + dx * co - dy * si,
            c[1] + dx * si + dy * co
        ]
    }

    function item_contains(item, x, y) {
        local p = this.item_local_point(item, x, y)
        return p[0] >= item.x && p[0] <= item.x + item.width &&
            p[1] >= item.y && p[1] <= item.y + item.height
    }

    function handle_points(item) {
        local x0 = item.x
        local y0 = item.y
        local x1 = item.x + item.width
        local y1 = item.y + item.height
        local xm = item.x + item.width / 2.0
        local ym = item.y + item.height / 2.0
        local lift = 42.0 / max_value(item.scale, 0.001)
        return {
            nw = [x0, y0],
            n = [xm, y0],
            ne = [x1, y0],
            e = [x1, ym],
            se = [x1, y1],
            s = [xm, y1],
            sw = [x0, y1],
            w = [x0, ym],
            rotate = [xm, y0 - lift]
        }
    }

    function handle_at(item, x, y) {
        local p = this.item_local_point(item, x, y)
        local handles = this.handle_points(item)
        local hit = 28.0 / max_value(item.scale, 0.001)
        local rotate_hit = 36.0 / max_value(item.scale, 0.001)
        foreach (name in ["rotate", "nw", "ne", "se", "sw"]) {
            local h = handles[name]
            local r = name == "rotate" ? rotate_hit : hit
            if (abs(p[0] - h[0]) <= r && abs(p[1] - h[1]) <= r) return name
        }

        local edge_hit = 18.0 / max_value(item.scale, 0.001)
        if (p[0] >= item.x - edge_hit && p[0] <= item.x + item.width + edge_hit) {
            if (abs(p[1] - item.y) <= edge_hit) return "n"
            if (abs(p[1] - (item.y + item.height)) <= edge_hit) return "s"
        }
        if (p[1] >= item.y - edge_hit && p[1] <= item.y + item.height + edge_hit) {
            if (abs(p[0] - item.x) <= edge_hit) return "w"
            if (abs(p[0] - (item.x + item.width)) <= edge_hit) return "e"
        }
        return null
    }

    function editor_hit_at(x, y) {
        local selected = this.selected()
        if (selected != null && selected.enabled) {
            local h = this.handle_at(selected, x, y)
            if (h != null) return { item = selected, action = h }
        }
        for (local i = this.items.len() - 1; i >= 0; i -= 1) {
            local item = this.items[i]
            if (!item.enabled) continue
            if (this.item_contains(item, x, y)) return { item = item, action = "move" }
        }
        return null
    }

    function item_at(x, y) {
        local h = this.editor_hit_at(x, y)
        return h == null ? null : h.item
    }
}

return {
    OverlayItem = OverlayItem,
    OverlayDocument = OverlayDocument
}
