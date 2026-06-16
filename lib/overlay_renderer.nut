local cairo = import("cairo")
local Gdk = import("Gdk", "4.0")
local Pb = import("GdkPixbuf")
local U = import("lib/utils.nut")

class OverlayRenderer {
    document = null
    telemetry = null
    image_cache = null

    constructor(document, telemetry) {
        this.document = document
        this.telemetry = telemetry
        this.image_cache = {}
    }

    function draw_background(cr, w, h) {
        local bg = cairo.Pattern.create_linear(0, 0, w, h)
        bg.add_color_stop_rgba(0.0, 0.055, 0.065, 0.07, 1.0)
        bg.add_color_stop_rgba(1.0, 0.012, 0.015, 0.018, 1.0)
        cr.set_source(bg)
        cr.rectangle(0, 0, w, h)
        cr.fill()

        local cell = 64.0
        for (local yy = 0.0; yy < h; yy += cell) {
            for (local xx = 0.0; xx < w; xx += cell) {
                local odd = (((xx / cell).tointeger() + (yy / cell).tointeger()) % 2) == 1
                cr.set_source_rgba(odd ? 0.16 : 0.10, odd ? 0.19 : 0.13, odd ? 0.20 : 0.15, 0.36)
                cr.rectangle(xx, yy, cell, cell)
                cr.fill()
            }
        }
    }

    function draw(cr, w, h, ts_s, selected_id = null) {
        local sx = w / this.document.video_width
        local sy = h / this.document.video_height
        cr.save()
        cr.scale(sx, sy)
        foreach (item in this.document.items) {
            if (item.enabled) this.draw_item(cr, item, ts_s, item.id == selected_id)
        }
        cr.restore()
    }

    function begin_item(cr, item) {
        local cx = item.x + item.width / 2.0
        local cy = item.y + item.height / 2.0
        cr.save()
        cr.translate(cx, cy)
        cr.rotate(item.rotation * 3.14159265359 / 180.0)
        cr.scale(item.scale, item.scale)
        cr.translate(-cx, -cy)
    }

    function draw_item(cr, item, ts_s, selected) {
        this.begin_item(cr, item)
        if (item.type == "scorebug") this.draw_scorebug(cr, item, ts_s)
        else if (item.type == "telemetry") this.draw_telemetry(cr, item)
        else if (item.type == "shape") this.draw_shape(cr, item)
        else if (item.type == "image") this.draw_image(cr, item)
        else if (item.type == "timer") this.draw_timer(cr, item, ts_s)
        else this.draw_text(cr, item)

        if (selected) this.draw_selection(cr, item)
        cr.restore()
    }

    function panel(cr, item, radius = 8.0) {
        local f = item.fill
        cr.set_source_rgba(f[0], f[1], f[2], f[3] * item.opacity)
        U.round_rect(cr, item.x, item.y, item.width, item.height, item.radius)
        cr.fill()
    }

    function accent(cr, item) {
        local s = item.stroke
        cr.set_source_rgba(s[0], s[1], s[2], s[3] * item.opacity)
        cr.rectangle(item.x, item.y, 7.0, item.height)
        cr.fill()
    }

    function apply_font(cr, item, size = null) {
        local slant = item.italic ? 1 : 0
        local weight = item.bold ? 1 : 0
        cr.select_font_face(item.font_family, slant, weight)
        cr.set_font_size(size == null ? item.font_size : size)
    }

    function text_x(item, text, size = null) {
        local font_size = size == null ? item.font_size : size
        local approx = text.len() * font_size * 0.55
        if (item.align == "right") return item.x + item.width - item.padding - approx
        if (item.align == "center") return item.x + (item.width - approx) / 2.0
        return item.x + item.padding
    }

    function draw_label(cr, item, text, y, size = null, alpha = 1.0) {
        local c = item.text_color
        this.apply_font(cr, item, size)
        if (item.shadow) {
            cr.set_source_rgba(0, 0, 0, 0.45 * item.opacity * alpha)
            cr.move_to(this.text_x(item, text, size) + 2.0, y + 2.0)
            cr.show_text(text)
        }
        cr.set_source_rgba(c[0], c[1], c[2], c[3] * item.opacity * alpha)
        cr.move_to(this.text_x(item, text, size), y)
        cr.show_text(text)
    }

    function format_value(value, decimals) {
        if (typeof value == "integer") return "" + value
        if (typeof value == "float") {
            if (decimals <= 0) return format("%d", value.tointeger())
            return format("%." + decimals + "f", value)
        }
        return "" + value
    }

    function field_text(item) {
        return item.prefix + this.format_value(this.telemetry.get_value(item.field, "--"), item.decimals) + item.suffix
    }

    function draw_scorebug(cr, item, ts_s) {
        this.panel(cr, item)
        this.accent(cr, item)
        this.draw_label(cr, item, format("%s %d    %s %d",
            this.telemetry.get_value("home_label", "HOME"),
            this.telemetry.get_value("home_score", 0),
            this.telemetry.get_value("away_label", "AWAY"),
            this.telemetry.get_value("away_score", 0)),
            item.y + item.font_size + item.padding)

        this.draw_label(cr, item, format("Stream %.1fs  %s", ts_s, this.telemetry.get_value("status", "")),
            item.y + item.height - item.padding, item.font_size * 0.52, 0.86)
    }

    function draw_telemetry(cr, item) {
        this.panel(cr, item)
        this.accent(cr, item)
        this.draw_label(cr, item, item.text, item.y + item.padding + item.font_size * 0.35,
            item.font_size * 0.58, 0.76)
        this.draw_label(cr, item, this.field_text(item), item.y + item.height - item.padding)
    }

    function draw_text(cr, item) {
        this.panel(cr, item)
        this.draw_label(cr, item, item.text, item.y + item.font_size + item.padding)
    }

    function draw_timer(cr, item, ts_s) {
        this.panel(cr, item)
        local total = ts_s.tointeger()
        local mins = total / 60
        local secs = total % 60
        this.draw_label(cr, item, format("%02d:%02d", mins, secs), item.y + item.font_size + item.padding)
    }

    function draw_shape(cr, item) {
        this.panel(cr, item)
        local s = item.stroke
        cr.set_source_rgba(s[0], s[1], s[2], s[3] * item.opacity)
        cr.set_line_width(3.0)
        U.round_rect(cr, item.x + 1.5, item.y + 1.5, item.width - 3.0, item.height - 3.0, 8.0)
        cr.stroke()
    }

    function image_for(item) {
        if (item.path.len() == 0) return null
        if (item.path in this.image_cache) return this.image_cache[item.path]
        try {
            local pix = Pb.Pixbuf.new_from_file(item.path)
            this.image_cache[item.path] <- pix
            return pix
        } catch (_) {
            this.image_cache[item.path] <- null
        }
        return null
    }

    function draw_image(cr, item) {
        this.panel(cr, item)
        local pix = this.image_for(item)
        if (pix != null) {
            local iw = pix.get_width().tofloat()
            local ih = pix.get_height().tofloat()
            local sx = item.width / iw
            local sy = item.height / ih
            local scale = item.fit == "cover" ? (sx > sy ? sx : sy) : (sx < sy ? sx : sy)
            local dw = iw * scale
            local dh = ih * scale
            cr.save()
            cr.rectangle(item.x, item.y, item.width, item.height)
            cr.clip()
            cr.translate(item.x + (item.width - dw) / 2.0, item.y + (item.height - dh) / 2.0)
            cr.scale(scale, scale)
            Gdk.cairo_set_source_pixbuf(cr, pix, 0, 0)
            cr.paint_with_alpha(item.opacity)
            cr.restore()
            return
        }

        local s = item.stroke
        cr.set_source_rgba(s[0], s[1], s[2], 0.85 * item.opacity)
        cr.set_line_width(3.0)
        cr.rectangle(item.x + 8.0, item.y + 8.0, item.width - 16.0, item.height - 16.0)
        cr.stroke()
        this.draw_label(cr, item, item.path.len() > 0 ? item.path : item.text,
            item.y + item.height / 2.0, 22.0)
    }

    function draw_selection(cr, item) {
        cr.set_source_rgba(1.0, 0.86, 0.22, 0.95)
        cr.set_line_width(2.0 / (item.scale > 0.001 ? item.scale : 1.0))
        cr.rectangle(item.x - 5.0, item.y - 5.0, item.width + 10.0, item.height + 10.0)
        cr.stroke()

        local hs = 20.0 / (item.scale > 0.001 ? item.scale : 1.0)
        local x0 = item.x
        local y0 = item.y
        local x1 = item.x + item.width
        local y1 = item.y + item.height
        local xm = item.x + item.width / 2.0
        local ym = item.y + item.height / 2.0
        foreach (p in [[x0,y0], [xm,y0], [x1,y0], [x1,ym], [x1,y1], [xm,y1], [x0,y1], [x0,ym]]) {
            cr.rectangle(p[0] - hs / 2.0, p[1] - hs / 2.0, hs, hs)
            cr.fill()
        }

        local lift = 48.0 / (item.scale > 0.001 ? item.scale : 1.0)
        cr.move_to(xm, y0 - 5.0)
        cr.line_to(xm, y0 - lift)
        cr.stroke()
        cr.arc(xm, y0 - lift, hs * 0.75, 0, 6.28318530718)
        cr.fill()
    }
}

return {
    OverlayRenderer = OverlayRenderer
}
