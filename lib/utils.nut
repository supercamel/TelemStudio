function clamp(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
}

function round_rect(cr, x, y, w, h, r) {
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -1.57079632679, 0.0)
    cr.arc(x + w - r, y + h - r, r, 0.0, 1.57079632679)
    cr.arc(x + r, y + h - r, r, 1.57079632679, 3.14159265359)
    cr.arc(x + r, y + r, r, 3.14159265359, 4.71238898038)
    cr.close_path()
}

function table_get(t, key, fallback) {
    return key in t ? t[key] : fallback
}

return {
    clamp = clamp,
    round_rect = round_rect,
    table_get = table_get,
    PI2 = 6.28318530718
}
