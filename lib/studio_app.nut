local GLib = import("GLib")
local Gio = import("Gio")
local Gdk = import("Gdk", "4.0")
local Gtk = import("Gtk", "4.0")

local T = import("lib/telemetry.nut")
local D = import("lib/overlay_document.nut")
local R = import("lib/overlay_renderer.nut")
local P = import("lib/pipeline_controller.nut")
local DS = import("lib/data_sources.nut")

local APP_NAME = "Telem Studio"
local APP_ID = "studio.telem.overlay"
local APP_ICON_NAME = APP_ID
local DESKTOP_RELAUNCH_ENV = "TELEM_STUDIO_DESKTOP_RELAUNCHED"

function index_of(list, value) {
    for (local i = 0; i < list.len(); i += 1) {
        if (list[i] == value) return i
    }
    return 0
}

function clamp(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
}

function hex_digit(c) {
    if (c >= "0" && c <= "9") return c.tointeger()
    if (c >= "a" && c <= "f") return 10 + "abcdef".find(c)
    if (c >= "A" && c <= "F") return 10 + "ABCDEF".find(c)
    return 0
}

function hex_pair(s, i) {
    return hex_digit(s.slice(i, i + 1)) * 16 + hex_digit(s.slice(i + 1, i + 2))
}

function color_to_hex(c) {
    return format("#%02X%02X%02X%02X",
        (clamp(c[0], 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c[1], 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c[2], 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c[3], 0.0, 1.0) * 255.0).tointeger())
}

function gdk_rgba_to_hex(c) {
    return format("#%02X%02X%02X%02X",
        (clamp(c.red, 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c.green, 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c.blue, 0.0, 1.0) * 255.0).tointeger(),
        (clamp(c.alpha, 0.0, 1.0) * 255.0).tointeger())
}

function set_color_button_hex(button, text) {
    if (button == null) return false
    try {
        local rgba = button.get_rgba()
        if (!rgba.parse(text)) return false
        button.set_rgba(rgba)
        return true
    } catch (_) {
        return false
    }
}

function parse_color(text, fallback) {
    local s = text
    if (s.len() > 0 && s.slice(0, 1) == "#") s = s.slice(1)
    if (s.len() != 6 && s.len() != 8) return fallback
    local a = s.len() == 8 ? hex_pair(s, 6) : 255
    return [
        hex_pair(s, 0) / 255.0,
        hex_pair(s, 2) / 255.0,
        hex_pair(s, 4) / 255.0,
        a / 255.0
    ]
}

function path_exists(path) {
    return Gio.File.new_for_path(path).query_exists(null)
}

function add_icon_search_path(theme, path) {
    if (path == null || path == "" || !path_exists(path)) return
    theme.add_search_path(path)
}

function register_app_icon() {
    local display = Gdk.Display.get_default()
    if (display == null) return

    local theme = Gtk.IconTheme.get_for_display(display)
    add_icon_search_path(theme, GLib.build_filenamev([GLib.get_current_dir(), "share"]))
    add_icon_search_path(theme, GLib.build_filenamev([GLib.get_current_dir(), "share", "icons"]))
    add_icon_search_path(theme, GLib.build_filenamev([GLib.get_current_dir(), "usr", "share", "icons"]))

    local appdir = GLib.getenv("SQGI_APPDIR")
    if (appdir != null && appdir != "") {
        add_icon_search_path(theme, GLib.build_filenamev([appdir, "share", "icons"]))
        add_icon_search_path(theme, GLib.build_filenamev([appdir, "usr", "share", "icons"]))
    }
}

function desktop_exec_quote(value) {
    local out = "\""
    for (local i = 0; i < value.len(); i += 1) {
        local ch = value.slice(i, i + 1)
        if (ch == "%") out += "%%"
        else if (ch == "\\" || ch == "\"" || ch == "$" || ch == "`") out += "\\" + ch
        else out += ch
    }
    return out + "\""
}

function desktop_launch_exec(appimage) {
    return "env " + DESKTOP_RELAUNCH_ENV + "=1 " + desktop_exec_quote(appimage) + " %U"
}

function remove_owned_desktop_file(path) {
    if (!path_exists(path)) return

    try {
        local text = GLib.file_get_contents(path)
        if (text.find(APP_NAME) == null) return
        if (text.find("X-TelemStudio-AppImage=true") == null &&
            text.find("StartupWMClass=" + APP_ID) == null) return
        GLib.remove(path)
    } catch (e) {
        print("desktop cleanup warning: " + e + "\n")
    }
}

function maybe_relaunch_from_desktop(desktop_path) {
    if (GLib.getenv("APPIMAGE") == null || GLib.getenv("APPIMAGE") == "") return false
    if (GLib.getenv(DESKTOP_RELAUNCH_ENV) == "1") return false
    if (GLib.getenv("TELEM_STUDIO_DISABLE_DESKTOP_RELAUNCH") == "1") return false

    try {
        local info = Gio.DesktopAppInfo.new(APP_ID + ".desktop")
        if (info == null) info = Gio.DesktopAppInfo.new_from_filename(desktop_path)
        if (info == null) return false
        return info.launch(null, null)
    } catch (e) {
        print("desktop relaunch warning: " + e + "\n")
        return false
    }
}

// GNOME/Wayland resolves dock icons through a desktop file visible to the shell.
function install_appimage_desktop_entry(app_id) {
    if (app_id != APP_ID) return null

    local appimage = GLib.getenv("APPIMAGE")
    if (appimage == null || appimage == "") return null

    local data_dir = GLib.get_user_data_dir()
    local appdir = GLib.getenv("SQGI_APPDIR")
    if (data_dir == null || data_dir == "" || appdir == null || appdir == "") return null

    try {
        local desktop_dir = GLib.build_filenamev([data_dir, "applications"])
        local icon_dir = GLib.build_filenamev([data_dir, "icons", "hicolor", "1024x1024", "apps"])
        GLib.mkdir_with_parents(desktop_dir, 493)
        GLib.mkdir_with_parents(icon_dir, 493)

        local desktop_path = GLib.build_filenamev([desktop_dir, APP_ID + ".desktop"])
        local icon_path = GLib.build_filenamev([icon_dir, APP_ICON_NAME + ".png"])
        local desktop_icon = APP_ICON_NAME

        remove_owned_desktop_file(GLib.build_filenamev([desktop_dir, "telemstudio.desktop"]))

        local icon_candidates = [
            GLib.build_filenamev([appdir, "usr", "share", "icons", "hicolor", "1024x1024", "apps", APP_ICON_NAME + ".png"]),
            GLib.build_filenamev([appdir, "share", "icons", "hicolor", "1024x1024", "apps", APP_ICON_NAME + ".png"]),
            GLib.build_filenamev([appdir, "share", "logo.png"]),
        ]
        foreach (src_path in icon_candidates) {
            if (!path_exists(src_path)) continue
            Gio.File.new_for_path(src_path).copy(
                Gio.File.new_for_path(icon_path),
                Gio.FileCopyFlags.overwrite,
                null,
                null
            )
            desktop_icon = icon_path
            break
        }

        local desktop =
            "[Desktop Entry]\n" +
            "Type=Application\n" +
            "Name=" + APP_NAME + "\n" +
            "Exec=" + desktop_launch_exec(appimage) + "\n" +
            "Icon=" + desktop_icon + "\n" +
            "Categories=AudioVideo;Video;GTK;\n" +
            "Terminal=false\n" +
            "StartupNotify=true\n" +
            "StartupWMClass=" + APP_ID + "\n" +
            "X-TelemStudio-AppImage=true\n"

        GLib.file_set_contents(desktop_path, desktop, -1)
        GLib.chmod(desktop_path, 493)

        return desktop_path
    } catch (e) {
        print("desktop integration warning: " + e + "\n")
    }
    return null
}

class StudioApp {
    app = null
    win = null
    document = null
    telemetry = null
    data_sources = null
    renderer = null
    source_config = null
    pipeline = null
    preview = null
    preview_event_widget = null
    preview_click_controller = null
    preview_drag_controller = null
    preview_key_controller = null
    last_click_info = null
    overlay_list = null
    status_label = null
    telemetry_label = null
    start_button = null
    stop_button = null

    source_kind_drop = null
    source_entry = null
    source_browse_button = null
    source_pattern_entry = null
    source_value_row = null
    source_value_label = null
    source_value_help = null
    source_pattern_row = null
    source_pattern_help = null
    width_adj = null
    height_adj = null
    fps_adj = null
    deinterlace_check = null
    loop_input_check = null
    flip_drop = null
    crop_top_adj = null
    crop_bottom_adj = null
    crop_left_adj = null
    crop_right_adj = null

    output_drop = null
    output_row = null
    output_label = null
    output_entry = null
    stream_key_row = null
    stream_key_label = null
    stream_key_entry = null
    udp_group = null
    encoding_group = null
    encoder_label = null
    container_label = null
    output_host_entry = null
    output_port_adj = null
    encoder_drop = null
    container_drop = null
    bitrate_adj = null
    preset_entry = null

    data_source_drop = null
    data_enabled_check = null
    data_url_entry = null
    data_host_entry = null
    data_port_adj = null
    data_interval_adj = null
    data_payload_entry = null
    data_prefix_entry = null

    name_entry = null
    text_entry = null
    field_row = null
    field_label = null
    field_entry = null
    field_browse_button = null
    prefix_entry = null
    suffix_entry = null
    font_entry = null
    fill_entry = null
    stroke_entry = null
    text_color_entry = null
    fill_color_button = null
    stroke_color_button = null
    text_color_button = null
    enabled_check = null
    bold_check = null
    italic_check = null
    shadow_check = null
    align_drop = null
    fit_drop = null
    x_adj = null
    y_adj = null
    w_adj = null
    h_adj = null
    scale_adj = null
    rotation_adj = null
    opacity_adj = null
    font_adj = null
    padding_adj = null
    radius_adj = null
    decimals_adj = null

    refreshing = false
    refreshing_data = false
    syncing_color = false
    shutting_down = false
    drag_item = null
    drag_mode = "move"
    drag_start_x = 0.0
    drag_start_y = 0.0
    drag_start_w = 0.0
    drag_start_h = 0.0
    drag_start_rotation = 0.0
    drag_start_angle = 0.0
    drag_origin_x = 0.0
    drag_origin_y = 0.0
    drag_widget_origin_x = 0.0
    drag_widget_origin_y = 0.0

    source_kind_values = ["test", "webcam", "uri", "custom"]
    output_kind_values = ["process", "preview", "file", "youtube", "facebook", "udp", "custom"]
    encoder_values = ["x264", "vp8", "jpeg"]
    container_values = ["matroska", "mp4", "webm", "mpegts"]
    flip_values = ["none", "horizontal-flip", "vertical-flip", "rotate-180"]
    align_values = ["left", "center", "right"]
    fit_values = ["contain", "cover"]

    constructor() {
        this.document = D.OverlayDocument()
        this.telemetry = T.TelemetryStore()
        this.data_sources = DS.DataSourceManager(this.telemetry)
        this.renderer = R.OverlayRenderer(this.document, this.telemetry)
        this.source_config = P.VideoSourceConfig()
        this.pipeline = P.PipelineController(this.document, this.renderer, this.source_config)
        this.pipeline.set_status_callback(function(text) { this.set_status(text) }.bindenv(this))
        GLib.set_prgname(APP_ID)
        GLib.set_application_name(APP_NAME)
        Gtk.Window.set_default_icon_name(APP_ICON_NAME)
        this.app = Gtk.Application.new(APP_ID, Gio.ApplicationFlags.flags_none)
        this.app.connect("activate", function() { this.activate() }.bindenv(this))
        this.app.connect("shutdown", function() { this.shutdown() }.bindenv(this))
    }

    function run(argc, argv) {
        return this.app.run(argc, argv)
    }

    function activate() {
        this.shutting_down = false
        local desktop_path = install_appimage_desktop_entry(APP_ID)
        if (desktop_path != null && maybe_relaunch_from_desktop(desktop_path)) return
        register_app_icon()
        this.data_sources.start()
        this.build_window()
        sqgi.timeout_add(100, function() {
            if (this.shutting_down || this.win == null) return false
            this.data_sources.tick()
            this.refresh_live_labels()
            this.queue_preview()
            return true
        }.bindenv(this))
        sqgi.timeout_add(100, function() {
            if (this.shutting_down) return false
            return this.pipeline.poll_bus()
        }.bindenv(this))
    }

    function shutdown() {
        if (this.shutting_down) return
        this.shutting_down = true
        if (this.data_sources != null) this.data_sources.stop()
        if (this.pipeline != null) {
            this.pipeline.set_status_callback(null)
            this.pipeline.stop()
        }
    }

    function request_close() {
        this.shutting_down = true
        if (this.data_sources != null) this.data_sources.stop()
        if (this.pipeline != null) {
            this.pipeline.set_status_callback(null)
            if (this.pipeline.pipe != null) {
                this.pipeline.stop()
                sqgi.timeout_add(150, function() {
                    this.app.quit()
                    return false
                }.bindenv(this))
                return
            }
        }
        this.app.quit()
    }

    function build_window() {
        this.win = Gtk.ApplicationWindow.new(this.app)
        this.win.set_title(APP_NAME)
        this.win.set_icon_name(APP_ICON_NAME)
        this.win.set_default_size(1500, 900)

        local header = Gtk.HeaderBar.new()
        local title = Gtk.Label.new(APP_NAME)
        title.add_css_class("title-4")
        header.set_title_widget(title)

        this.start_button = Gtk.Button.new_with_label("Start")
        this.start_button.connect("clicked", function() { this.start_pipeline() }.bindenv(this))
        header.pack_start(this.start_button)

        this.stop_button = Gtk.Button.new_with_label("Stop")
        this.stop_button.set_sensitive(false)
        this.stop_button.connect("clicked", function() { this.stop_pipeline() }.bindenv(this))
        header.pack_start(this.stop_button)
        this.win.set_titlebar(header)

        local root = Gtk.Box.new(Gtk.Orientation.vertical, 0)
        this.win.set_child(root)

        local main = Gtk.Box.new(Gtk.Orientation.horizontal, 0)
        main.set_vexpand(true)
        root.append(main)

        main.append(this.build_config_panel())
        main.append(this.build_preview_panel())
        main.append(this.build_inspector())

        local status_bar = Gtk.Box.new(Gtk.Orientation.horizontal, 8)
        status_bar.set_margin_top(8)
        status_bar.set_margin_bottom(8)
        status_bar.set_margin_start(12)
        status_bar.set_margin_end(12)
        this.status_label = Gtk.Label.new("Ready")
        this.status_label.set_xalign(0.0)
        this.status_label.set_hexpand(true)
        status_bar.append(this.status_label)
        root.append(status_bar)

        this.win.connect("close-request", function() {
            this.request_close()
            return true
        }.bindenv(this))

        this.refresh_source_controls()
        this.refresh_data_source_controls()
        this.rebuild_overlay_list()
        this.refresh_inspector()
        this.refresh_live_labels()
        this.win.present()
    }

    function section(panel, text) {
        local label = Gtk.Label.new(text)
        label.add_css_class("title-4")
        label.set_xalign(0.0)
        label.set_margin_top(12)
        panel.append(label)
        return label
    }

    function make_page() {
        local panel = Gtk.Box.new(Gtk.Orientation.vertical, 8)
        panel.set_margin_top(12)
        panel.set_margin_bottom(12)
        panel.set_margin_start(12)
        panel.set_margin_end(12)
        return panel
    }

    function add_page(book, title, child) {
        local label = Gtk.Label.new(title)
        book.append_page(child, label)
    }

    function make_group(panel, title, expanded = true) {
        local expander = Gtk.Expander.new(title)
        expander.set_expanded(expanded)
        expander.set_margin_top(4)

        local box = Gtk.Box.new(Gtk.Orientation.vertical, 8)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(8)
        box.set_margin_end(8)
        expander.set_child(box)
        panel.append(expander)
        return box
    }

    function make_help(panel, text) {
        local help = Gtk.Label.new(text)
        help.add_css_class("dim-label")
        help.set_xalign(0.0)
        help.set_wrap(true)
        panel.append(help)
        return help
    }

    function make_entry(panel, label_text, on_change = null) {
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        panel.append(label)
        local entry = Gtk.Entry.new()
        if (on_change != null) entry.connect("changed", on_change)
        panel.append(entry)
        return entry
    }

    function make_color_entry(panel, label_text, on_change = null) {
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        panel.append(label)

        local row = Gtk.Box.new(Gtk.Orientation.horizontal, 6)
        local entry = Gtk.Entry.new()
        entry.set_hexpand(true)
        local button = Gtk.ColorButton.new()
        button.set_use_alpha(true)

        entry.connect("changed", function() {
            if (this.syncing_color) return
            this.syncing_color = true
            set_color_button_hex(button, entry.get_text())
            this.syncing_color = false
            if (on_change != null) on_change()
        }.bindenv(this))

        button.connect("notify::rgba", function(pspec) {
            if (this.syncing_color) return
            this.syncing_color = true
            entry.set_text(gdk_rgba_to_hex(button.get_rgba()))
            this.syncing_color = false
            if (on_change != null) on_change()
        }.bindenv(this))

        row.append(entry)
        row.append(button)
        panel.append(row)
        return { entry = entry, button = button }
    }

    function make_entry_group(panel, label_text, help_text, on_change = null) {
        local box = Gtk.Box.new(Gtk.Orientation.vertical, 4)
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        box.append(label)
        local entry = Gtk.Entry.new()
        if (on_change != null) entry.connect("changed", on_change)
        box.append(entry)
        local help = Gtk.Label.new(help_text)
        help.add_css_class("dim-label")
        help.set_xalign(0.0)
        help.set_wrap(true)
        box.append(help)
        panel.append(box)
        return { row = box, label = label, entry = entry, help = help }
    }

    function make_entry_group_action(panel, label_text, button_text, help_text, on_change = null, on_click = null) {
        local box = Gtk.Box.new(Gtk.Orientation.vertical, 4)
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        box.append(label)

        local row = Gtk.Box.new(Gtk.Orientation.horizontal, 6)
        local entry = Gtk.Entry.new()
        entry.set_hexpand(true)
        if (on_change != null) entry.connect("changed", on_change)
        local button = Gtk.Button.new_with_label(button_text)
        if (on_click != null) button.connect("clicked", on_click)
        row.append(entry)
        row.append(button)
        box.append(row)

        local help = Gtk.Label.new(help_text)
        help.add_css_class("dim-label")
        help.set_xalign(0.0)
        help.set_wrap(true)
        box.append(help)
        panel.append(box)
        return { row = box, label = label, entry = entry, button = button, help = help }
    }

    function make_check(panel, label_text, on_change = null) {
        local check = Gtk.CheckButton.new_with_label(label_text)
        if (on_change != null) check.connect("toggled", on_change)
        panel.append(check)
        return check
    }

    function make_drop(panel, label_text, labels, on_change = null) {
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        panel.append(label)
        local drop = Gtk.DropDown.new(Gtk.StringList.new(labels), null)
        if (on_change != null) drop.connect("notify::selected", on_change)
        panel.append(drop)
        return drop
    }

    function make_drop_group(panel, label_text, labels, on_change = null) {
        local box = Gtk.Box.new(Gtk.Orientation.vertical, 4)
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        box.append(label)
        local drop = Gtk.DropDown.new(Gtk.StringList.new(labels), null)
        if (on_change != null) drop.connect("notify::selected", on_change)
        box.append(drop)
        panel.append(box)
        return { row = box, label = label, drop = drop }
    }

    function set_panel_visible(panel, visible) {
        if (panel == null) return
        local parent = panel.get_parent()
        if (parent != null) parent.set_visible(visible)
        else panel.set_visible(visible)
    }

    function make_adjustment(panel, label_text, lo, hi, step, on_change = null) {
        local row = Gtk.Box.new(Gtk.Orientation.horizontal, 8)
        local label = Gtk.Label.new(label_text)
        label.set_xalign(0.0)
        label.set_hexpand(true)
        local adj = Gtk.Adjustment.new(lo, lo, hi, step, step * 8.0, 0.0)
        local spin = Gtk.SpinButton.new(adj, step, step < 1.0 ? 2 : 0)
        spin.set_width_chars(8)
        if (on_change != null) adj.connect("value-changed", on_change)
        row.append(label)
        row.append(spin)
        panel.append(row)
        return adj
    }

    function make_overlay_button(label, action) {
        local b = Gtk.Button.new_with_label(label)
        b.connect("clicked", function() { this.add_item(action) }.bindenv(this))
        return b
    }

    function build_config_panel() {
        local book = Gtk.Notebook.new()
        book.set_size_request(410, -1)

        local input = this.make_page()
        this.make_help(input, "Choose where video comes from, then normalize it for the overlay canvas.")
        this.source_kind_drop = this.make_drop(input, "Input source", [
            "Test pattern", "Webcam", "URI / file / HTTP / RTSP", "Custom GStreamer source"
        ], function(pspec) { this.apply_source_controls() }.bindenv(this))
        local source_value = this.make_entry_group_action(input, "Source", "Browse...", "",
            function() { this.apply_source_controls() }.bindenv(this),
            function() { this.open_source_file_dialog() }.bindenv(this))
        this.source_value_row = source_value.row
        this.source_value_label = source_value.label
        this.source_entry = source_value.entry
        this.source_browse_button = source_value.button
        this.source_value_help = source_value.help
        local source_pattern = this.make_entry_group(input, "Pattern", "",
            function() { this.apply_source_controls() }.bindenv(this))
        this.source_pattern_row = source_pattern.row
        this.source_pattern_entry = source_pattern.entry
        this.source_pattern_help = source_pattern.help
        this.loop_input_check = this.make_check(input, "Loop file / URI when it reaches the end",
            function() { this.apply_source_controls() }.bindenv(this))

        local format_group = this.make_group(input, "Canvas format", true)
        this.width_adj = this.make_adjustment(format_group, "Output width", 160, 7680, 10,
            function() { this.apply_source_controls() }.bindenv(this))
        this.height_adj = this.make_adjustment(format_group, "Output height", 90, 4320, 10,
            function() { this.apply_source_controls() }.bindenv(this))
        this.fps_adj = this.make_adjustment(format_group, "FPS", 1, 240, 1,
            function() { this.apply_source_controls() }.bindenv(this))

        local cleanup_group = this.make_group(input, "Input cleanup", false)
        this.deinterlace_check = this.make_check(cleanup_group, "Deinterlace",
            function() { this.apply_source_controls() }.bindenv(this))
        this.flip_drop = this.make_drop(cleanup_group, "Flip / rotate", [
            "None", "Horizontal", "Vertical", "Rotate 180"
        ], function(pspec) { this.apply_source_controls() }.bindenv(this))
        this.crop_top_adj = this.make_adjustment(cleanup_group, "Crop top", 0, 2000, 1,
            function() { this.apply_source_controls() }.bindenv(this))
        this.crop_bottom_adj = this.make_adjustment(cleanup_group, "Crop bottom", 0, 2000, 1,
            function() { this.apply_source_controls() }.bindenv(this))
        this.crop_left_adj = this.make_adjustment(cleanup_group, "Crop left", 0, 2000, 1,
            function() { this.apply_source_controls() }.bindenv(this))
        this.crop_right_adj = this.make_adjustment(cleanup_group, "Crop right", 0, 2000, 1,
            function() { this.apply_source_controls() }.bindenv(this))
        this.add_page(book, "Input", input)

        local output = this.make_page()
        this.make_help(output, "Pick the destination first; encoder and container options stay nearby when you need them.")
        this.output_drop = this.make_drop(output, "Destination", [
            "Process only (no video window)", "Preview window", "Record file", "YouTube Live", "Facebook Live", "UDP MPEG-TS", "Custom sink"
        ], function(pspec) { this.apply_source_controls() }.bindenv(this))

        local output_value = this.make_entry_group(output, "Record file path", "",
            function() { this.apply_source_controls() }.bindenv(this))
        this.output_row = output_value.row
        this.output_label = output_value.label
        this.output_entry = output_value.entry

        local stream_key_value = this.make_entry_group(output, "Stream key", "",
            function() { this.apply_source_controls() }.bindenv(this))
        this.stream_key_row = stream_key_value.row
        this.stream_key_label = stream_key_value.label
        this.stream_key_entry = stream_key_value.entry
        this.stream_key_entry.set_visibility(false)

        this.udp_group = this.make_group(output, "UDP stream", false)
        this.output_host_entry = this.make_entry(this.udp_group, "Host",
            function() { this.apply_source_controls() }.bindenv(this))
        this.output_port_adj = this.make_adjustment(this.udp_group, "Port", 1, 65535, 1,
            function() { this.apply_source_controls() }.bindenv(this))

        this.encoding_group = this.make_group(output, "Encoding", true)
        local encoder = this.make_drop_group(this.encoding_group, "Encoder", ["H.264 x264", "VP8", "MJPEG"],
            function(pspec) { this.apply_source_controls() }.bindenv(this))
        this.encoder_label = encoder.label
        this.encoder_drop = encoder.drop
        local container = this.make_drop_group(this.encoding_group, "Container", ["Matroska", "MP4", "WebM", "MPEG-TS"],
            function(pspec) { this.apply_source_controls() }.bindenv(this))
        this.container_label = container.label
        this.container_drop = container.drop
        this.bitrate_adj = this.make_adjustment(this.encoding_group, "Video bitrate kbps", 250, 50000, 250,
            function() { this.apply_source_controls() }.bindenv(this))
        this.preset_entry = this.make_entry(this.encoding_group, "x264 speed preset",
            function() { this.apply_source_controls() }.bindenv(this))
        this.add_page(book, "Output", output)

        local data = this.make_page()
        this.make_help(data, "Connect live values that text overlays can display by field name.")
        this.data_source_drop = this.make_drop(data, "Data source", [
            "HTTP JSON poll", "HTTP JSON POST endpoint", "TCP text/json poll", "UDP text/json listener"
        ], function(pspec) { this.refresh_data_source_controls() }.bindenv(this))
        this.data_enabled_check = this.make_check(data, "Enabled",
            function() { this.apply_data_source_controls() }.bindenv(this))

        local connection_group = this.make_group(data, "Connection", true)
        this.data_url_entry = this.make_entry(connection_group, "HTTP URL / POST path",
            function() { this.apply_data_source_controls() }.bindenv(this))
        this.data_host_entry = this.make_entry(connection_group, "Host / bind address",
            function() { this.apply_data_source_controls() }.bindenv(this))
        this.data_port_adj = this.make_adjustment(connection_group, "Port", 1, 65535, 1,
            function() { this.apply_data_source_controls() }.bindenv(this))

        local polling_group = this.make_group(data, "Polling and fields", true)
        this.data_interval_adj = this.make_adjustment(polling_group, "Poll interval ms", 50, 60000, 50,
            function() { this.apply_data_source_controls() }.bindenv(this))
        this.data_payload_entry = this.make_entry(polling_group, "TCP request payload",
            function() { this.apply_data_source_controls() }.bindenv(this))
        this.data_prefix_entry = this.make_entry(polling_group, "Field prefix",
            function() { this.apply_data_source_controls() }.bindenv(this))

        this.telemetry_label = Gtk.Label.new("")
        this.telemetry_label.set_xalign(0.0)
        this.telemetry_label.set_wrap(true)
        this.telemetry_label.add_css_class("dim-label")
        data.append(this.telemetry_label)
        this.add_page(book, "Data", data)

        local layers = this.make_page()
        this.make_help(layers, "Add overlay elements, select a layer, then edit it in the inspector or directly on the canvas.")
        local add_group = this.make_group(layers, "Add overlay", true)
        foreach (row in [
            [
                { label = "Text", action = "text" },
                { label = "Data", action = "telemetry" },
                { label = "Score", action = "score" }
            ],
            [
                { label = "Box", action = "shape" },
                { label = "Image", action = "image" },
                { label = "Timer", action = "timer" }
            ]
        ]) {
            local add_row = Gtk.Box.new(Gtk.Orientation.horizontal, 6)
            foreach (spec in row) {
                local b = this.make_overlay_button(spec.label, spec.action)
                b.set_hexpand(true)
                add_row.append(b)
            }
            add_group.append(add_row)
        }

        local layer_group = this.make_group(layers, "Layer stack", true)
        this.overlay_list = Gtk.ListBox.new()
        this.overlay_list.set_selection_mode(Gtk.SelectionMode.single)
        this.overlay_list.connect("row-selected", function(row) {
            if (row == null) return
            local idx = row.get_index()
            if (idx >= 0 && idx < this.document.items.len()) {
                this.document.select_id(this.document.items[idx].id)
                this.refresh_inspector()
                this.queue_preview()
            }
        }.bindenv(this))
        local list_scroll = Gtk.ScrolledWindow.new()
        list_scroll.set_min_content_height(220)
        list_scroll.set_child(this.overlay_list)
        layer_group.append(list_scroll)

        local order_row = Gtk.Box.new(Gtk.Orientation.horizontal, 6)
        local back = Gtk.Button.new_with_label("Back")
        back.connect("clicked", function() {
            this.document.send_backward()
            this.rebuild_overlay_list()
            this.queue_preview()
        }.bindenv(this))
        local front = Gtk.Button.new_with_label("Front")
        front.connect("clicked", function() {
            this.document.bring_forward()
            this.rebuild_overlay_list()
            this.queue_preview()
        }.bindenv(this))
        local del = Gtk.Button.new_with_label("Delete")
        del.connect("clicked", function() {
            this.document.delete_selected()
            this.rebuild_overlay_list()
            this.refresh_inspector()
            this.queue_preview()
        }.bindenv(this))
        order_row.append(back)
        order_row.append(front)
        order_row.append(del)
        layer_group.append(order_row)
        this.add_page(book, "Layers", layers)

        return book
    }

    function build_preview_panel() {
        local panel = Gtk.Box.new(Gtk.Orientation.vertical, 0)
        panel.set_hexpand(true)
        panel.set_vexpand(true)

        local preview_stack = Gtk.Overlay.new()
        preview_stack.set_can_target(true)
        preview_stack.set_focusable(true)
        preview_stack.set_hexpand(true)
        preview_stack.set_vexpand(true)
        preview_stack.set_size_request(780, 460)
        this.preview_event_widget = preview_stack

        this.preview = Gtk.DrawingArea.new()
        this.preview.set_can_target(true)
        this.preview.set_focusable(true)
        this.preview.set_hexpand(true)
        this.preview.set_vexpand(true)
        this.preview.set_size_request(780, 460)
        this.preview.set_draw_func(function(area, cr, w, h) {
            local ts = this.pipeline.started_us > 0
                ? ((GLib.get_monotonic_time() - this.pipeline.started_us) / 1000000.0)
                : ((GLib.get_monotonic_time() - this.data_sources.start_us) / 1000000.0)
            this.draw_preview_source(cr, w.tofloat(), h.tofloat(), ts)
            this.renderer.draw(cr, w.tofloat(), h.tofloat(), ts, this.document.selected_id)
            cr.set_source_rgba(1, 1, 1, 0.62)
            cr.select_font_face("Sans", 0, 0)
            cr.set_font_size(13.0)
            cr.move_to(18.0, h - 18.0)
            cr.show_text(format("%dx%d @ %dfps. Drag overlays, edge/corner handles resize, top handle rotates.",
                this.source_config.width, this.source_config.height, this.source_config.fps))
        }.bindenv(this), null, function(_) {})

        preview_stack.set_child(this.preview)
        this.install_preview_interactions()

        panel.append(preview_stack)
        return panel
    }

    function draw_preview_source(cr, w, h, ts) {
        local pix = this.pipeline.preview_pixbuf()
        if (pix != null) {
            local pw = pix.get_width().tofloat()
            local ph = pix.get_height().tofloat()
            if (pw > 0.0 && ph > 0.0) {
                cr.save()
                cr.scale(w / pw, h / ph)
                Gdk.cairo_set_source_pixbuf(cr, pix, 0, 0)
                cr.rectangle(0, 0, pw, ph)
                cr.fill()
                cr.restore()
                return
            }
        }

        this.renderer.draw_background(cr, w, h)
        cr.set_source_rgba(1, 1, 1, 0.42)
        cr.select_font_face("Sans", 0, 0)
        cr.set_font_size(18.0)
        cr.move_to(24.0, 42.0)
        if (this.pipeline.pipe != null) {
            cr.show_text("Waiting for live preview frames...")
            return
        }
        cr.show_text("Start the pipeline to see the live source preview.")
    }

    function install_preview_interactions() {
        local target = this.preview_event_widget != null ? this.preview_event_widget : this.preview
        this.preview_click_controller = Gtk.GestureClick.new()
        this.preview_click_controller.set_button(0)
        this.preview_click_controller.set_exclusive(false)
        this.preview_click_controller.set_propagation_phase(Gtk.PropagationPhase.capture)
        this.preview_click_controller.connect("pressed", function(n_press, x, y) {
            this.handle_preview_pressed(this.preview_click_controller, n_press, x, y)
        }.bindenv(this))
        this.preview_click_controller.connect("released", function(n_press, x, y) {
            this.handle_preview_released(this.preview_click_controller, n_press, x, y)
        }.bindenv(this))
        target.add_controller(this.preview_click_controller)

        this.preview_drag_controller = Gtk.GestureDrag.new()
        this.preview_drag_controller.set_button(1)
        this.preview_drag_controller.set_exclusive(false)
        this.preview_drag_controller.set_propagation_phase(Gtk.PropagationPhase.capture)
        this.preview_drag_controller.connect("drag-begin", function(x, y) {
            target.grab_focus()
            this.begin_editor_action(x, y)
        }.bindenv(this))
        this.preview_drag_controller.connect("drag-update", function(dx, dy) {
            if (this.drag_item == null) return
            this.apply_editor_drag(dx, dy)
            this.refresh_inspector()
            this.queue_preview()
        }.bindenv(this))
        this.preview_drag_controller.connect("drag-end", function(dx, dy) {
            this.drag_item = null
        }.bindenv(this))
        target.add_controller(this.preview_drag_controller)

        this.preview_key_controller = Gtk.EventControllerKey.new()
        this.preview_key_controller.connect("key-pressed", function(keyval, keycode, state) {
            return this.handle_preview_key(keyval, state)
        }.bindenv(this))
        target.add_controller(this.preview_key_controller)
    }

    function current_event_state(controller) {
        try { return controller.get_current_event_state() } catch (_) {}
        return 0
    }

    function current_button(gesture) {
        try { return gesture.get_current_button() } catch (_) {}
        return 0
    }

    function handle_preview_pressed(gesture, n_press, x, y) {
        local target = this.preview_event_widget != null ? this.preview_event_widget : this.preview
        target.grab_focus()
        local button = this.current_button(gesture)
        local state = this.current_event_state(gesture)
        this.last_click_info = {
            x = x,
            y = y,
            button = button,
            count = n_press,
            state = state
        }
        if (button == 0 || button == 1) {
            this.begin_editor_action(x, y)
        } else {
            this.set_status(format("Preview click button %d at %.0f, %.0f", button, x, y))
        }
    }

    function handle_preview_released(gesture, n_press, x, y) {
        local button = this.current_button(gesture)
        local state = this.current_event_state(gesture)
        this.last_click_info = {
            x = x,
            y = y,
            button = button,
            count = n_press,
            state = state
        }
        this.drag_item = null
    }

    function begin_editor_action(x, y) {
        local p = this.preview_to_video(x, y)
        local hit = this.document.editor_hit_at(p[0], p[1])
        this.drag_item = hit == null ? null : hit.item
        if (this.drag_item == null) {
            this.document.select_id(null)
            this.set_status("No overlay selected")
            this.refresh_inspector()
            this.queue_preview()
            return
        }

        this.document.select_id(this.drag_item.id)
        this.drag_start_x = this.drag_item.x
        this.drag_start_y = this.drag_item.y
        this.drag_start_w = this.drag_item.width
        this.drag_start_h = this.drag_item.height
        this.drag_start_rotation = this.drag_item.rotation
        this.drag_origin_x = p[0]
        this.drag_origin_y = p[1]
        this.drag_widget_origin_x = x
        this.drag_widget_origin_y = y
        local c = this.document.item_center(this.drag_item)
        this.drag_start_angle = atan2(p[1] - c[1], p[0] - c[0])
        this.drag_mode = hit.action
        this.set_status("Editing " + this.drag_item.name + " (" + this.drag_mode + ")")
        this.rebuild_overlay_list()
        this.refresh_inspector()
        this.queue_preview()
    }

    function apply_editor_drag(dx, dy) {
        local delta = this.preview_delta_to_video(dx, dy)
        if (this.drag_mode == "move") {
            this.drag_item.x = clamp(this.drag_start_x + delta[0], -this.drag_start_w, this.document.video_width)
            this.drag_item.y = clamp(this.drag_start_y + delta[1], -this.drag_start_h, this.document.video_height)
            return
        }

        if (this.drag_mode == "rotate") {
            local c = [
                this.drag_start_x + this.drag_start_w / 2.0,
                this.drag_start_y + this.drag_start_h / 2.0
            ]
            local current_angle = atan2(this.drag_origin_y + delta[1] - c[1],
                this.drag_origin_x + delta[0] - c[0])
            this.drag_item.rotation = this.drag_start_rotation +
                (current_angle - this.drag_start_angle) * 180.0 / 3.14159265359
            return
        }

        local r = -this.drag_start_rotation * 3.14159265359 / 180.0
        local co = cos(r)
        local si = sin(r)
        local sc = this.drag_item.scale > 0.001 ? this.drag_item.scale : 1.0
        local ldx = (delta[0] * co - delta[1] * si) / sc
        local ldy = (delta[0] * si + delta[1] * co) / sc
        local min_size = 8.0
        local x = this.drag_start_x
        local y = this.drag_start_y
        local w = this.drag_start_w
        local h = this.drag_start_h

        if (this.drag_mode.find("e") != null) w = this.drag_start_w + ldx
        if (this.drag_mode.find("s") != null) h = this.drag_start_h + ldy
        if (this.drag_mode.find("w") != null) {
            x = this.drag_start_x + ldx
            w = this.drag_start_w - ldx
        }
        if (this.drag_mode.find("n") != null) {
            y = this.drag_start_y + ldy
            h = this.drag_start_h - ldy
        }

        if (w < min_size) {
            if (this.drag_mode.find("w") != null) x = this.drag_start_x + this.drag_start_w - min_size
            w = min_size
        }
        if (h < min_size) {
            if (this.drag_mode.find("n") != null) y = this.drag_start_y + this.drag_start_h - min_size
            h = min_size
        }

        this.drag_item.x = clamp(x, -this.document.video_width, this.document.video_width)
        this.drag_item.y = clamp(y, -this.document.video_height, this.document.video_height)
        this.drag_item.width = clamp(w, min_size, this.document.video_width * 2.0)
        this.drag_item.height = clamp(h, min_size, this.document.video_height * 2.0)
    }

    function handle_preview_key(keyval, state) {
        local item = this.document.selected()
        if (item == null) return false
        local big = (state & Gdk.ModifierType.shift_mask) != 0
        local step = big ? 10.0 : 1.0
        if (keyval == Gdk.KEY_Left) item.x -= step
        else if (keyval == Gdk.KEY_Right) item.x += step
        else if (keyval == Gdk.KEY_Up) item.y -= step
        else if (keyval == Gdk.KEY_Down) item.y += step
        else if (keyval == Gdk.KEY_Delete || keyval == Gdk.KEY_BackSpace) {
            this.document.delete_selected()
            this.rebuild_overlay_list()
            this.refresh_inspector()
            this.queue_preview()
            return true
        } else if (keyval == Gdk.KEY_Page_Up) {
            this.document.bring_forward()
            this.rebuild_overlay_list()
        } else if (keyval == Gdk.KEY_Page_Down) {
            this.document.send_backward()
            this.rebuild_overlay_list()
        } else {
            return false
        }
        this.refresh_inspector()
        this.queue_preview()
        return true
    }

    function preview_to_video(x, y) {
        local target = this.preview_event_widget != null ? this.preview_event_widget : this.preview
        local w = target.get_allocated_width().tofloat()
        local h = target.get_allocated_height().tofloat()
        return [x * this.document.video_width / w, y * this.document.video_height / h]
    }

    function preview_delta_to_video(dx, dy) {
        local target = this.preview_event_widget != null ? this.preview_event_widget : this.preview
        local w = target.get_allocated_width().tofloat()
        local h = target.get_allocated_height().tofloat()
        return [dx * this.document.video_width / w, dy * this.document.video_height / h]
    }

    function build_inspector() {
        local panel = this.make_page()

        local basics = this.make_group(panel, "Selected overlay", true)
        this.enabled_check = this.make_check(basics, "Visible", function() { this.apply_inspector() }.bindenv(this))
        this.name_entry = this.make_entry(basics, "Name", function() { this.apply_inspector() }.bindenv(this))
        this.text_entry = this.make_entry(basics, "Text / label", function() { this.apply_inspector() }.bindenv(this))
        local field_value = this.make_entry_group_action(basics, "Data field", "Choose...", "",
            function() { this.apply_inspector() }.bindenv(this),
            function() { this.open_image_overlay_dialog() }.bindenv(this))
        this.field_row = field_value.row
        this.field_label = field_value.label
        this.field_entry = field_value.entry
        this.field_browse_button = field_value.button
        this.prefix_entry = this.make_entry(basics, "Value prefix", function() { this.apply_inspector() }.bindenv(this))
        this.suffix_entry = this.make_entry(basics, "Value suffix", function() { this.apply_inspector() }.bindenv(this))
        this.decimals_adj = this.make_adjustment(basics, "Data decimals", 0.0, 6.0, 1.0, function() { this.apply_inspector() }.bindenv(this))

        local transform = this.make_group(panel, "Position and size", true)
        this.x_adj = this.make_adjustment(transform, "X", -2000.0, 7680.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.y_adj = this.make_adjustment(transform, "Y", -2000.0, 4320.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.w_adj = this.make_adjustment(transform, "Width", 8.0, 7680.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.h_adj = this.make_adjustment(transform, "Height", 8.0, 4320.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.scale_adj = this.make_adjustment(transform, "Scale", 0.05, 10.0, 0.05, function() { this.apply_inspector() }.bindenv(this))
        this.rotation_adj = this.make_adjustment(transform, "Rotation", -180.0, 180.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.opacity_adj = this.make_adjustment(transform, "Opacity", 0.0, 1.0, 0.05, function() { this.apply_inspector() }.bindenv(this))

        local type_group = this.make_group(panel, "Type-specific options", true)
        this.align_drop = this.make_drop(type_group, "Text align", ["Left", "Center", "Right"],
            function(pspec) { this.apply_inspector() }.bindenv(this))
        this.fit_drop = this.make_drop(type_group, "Image fit", ["Contain", "Cover"],
            function(pspec) { this.apply_inspector() }.bindenv(this))
        this.padding_adj = this.make_adjustment(type_group, "Padding", 0.0, 160.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.radius_adj = this.make_adjustment(type_group, "Corner radius", 0.0, 160.0, 1.0, function() { this.apply_inspector() }.bindenv(this))

        local typography = this.make_group(panel, "Typography", false)
        this.font_entry = this.make_entry(typography, "Font family", function() { this.apply_inspector() }.bindenv(this))
        this.font_adj = this.make_adjustment(typography, "Font size", 8.0, 180.0, 1.0, function() { this.apply_inspector() }.bindenv(this))
        this.bold_check = this.make_check(typography, "Bold", function() { this.apply_inspector() }.bindenv(this))
        this.italic_check = this.make_check(typography, "Italic", function() { this.apply_inspector() }.bindenv(this))
        this.shadow_check = this.make_check(typography, "Text shadow", function() { this.apply_inspector() }.bindenv(this))

        local colors = this.make_group(panel, "Colors", false)
        local fill_color = this.make_color_entry(colors, "Fill", function() { this.apply_inspector() }.bindenv(this))
        this.fill_entry = fill_color.entry
        this.fill_color_button = fill_color.button
        local stroke_color = this.make_color_entry(colors, "Accent", function() { this.apply_inspector() }.bindenv(this))
        this.stroke_entry = stroke_color.entry
        this.stroke_color_button = stroke_color.button
        local text_color = this.make_color_entry(colors, "Text", function() { this.apply_inspector() }.bindenv(this))
        this.text_color_entry = text_color.entry
        this.text_color_button = text_color.button

        local scrolled = Gtk.ScrolledWindow.new()
        scrolled.set_size_request(370, -1)
        scrolled.set_child(panel)
        return scrolled
    }

    function source_value_for_kind(kind) {
        if (kind == "webcam") return this.source_config.device
        if (kind == "uri") return this.source_config.uri
        if (kind == "custom") return this.source_config.custom_source
        return ""
    }

    function output_value_for_kind(kind) {
        if (kind == "custom") return this.source_config.custom_sink
        if (kind == "youtube") return this.source_config.youtube_server_url
        if (kind == "facebook") return this.source_config.facebook_server_url
        if (kind == "rtmp") return this.source_config.stream_uri
        return this.source_config.output_path
    }

    function stream_key_for_kind(kind) {
        if (kind == "youtube") return this.source_config.youtube_stream_key
        if (kind == "facebook") return this.source_config.facebook_stream_key
        return ""
    }

    function open_source_file_dialog() {
        local dialog = Gtk.FileChooserNative.new("Open Input Video", this.win,
            Gtk.FileChooserAction.open, "Open", "Cancel")
        dialog.set_modal(true)

        local video_filter = Gtk.FileFilter.new()
        video_filter.set_name("Video files")
        foreach (mime in ["video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo", "video/mpeg"]) {
            video_filter.add_mime_type(mime)
        }
        foreach (pattern in ["*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.mpeg", "*.mpg", "*.ts", "*.m4v"]) {
            video_filter.add_pattern(pattern)
        }
        dialog.add_filter(video_filter)

        local all_filter = Gtk.FileFilter.new()
        all_filter.set_name("All files")
        all_filter.add_pattern("*")
        dialog.add_filter(all_filter)

        dialog.connect("response", function(response) {
            if (response == Gtk.ResponseType.accept || response == Gtk.ResponseType.ok) {
                local file = dialog.get_file()
                if (file != null) {
                    this.source_entry.set_text(file.get_uri())
                    this.apply_source_controls()
                    this.set_status("Selected input video " + file.get_parse_name())
                }
            }
            dialog.destroy()
        }.bindenv(this))
        dialog.show()
    }

    function open_image_overlay_dialog() {
        local item = this.document.selected()
        if (item == null || item.type != "image") return

        local dialog = Gtk.FileChooserNative.new("Choose Overlay Image", this.win,
            Gtk.FileChooserAction.open, "Open", "Cancel")
        dialog.set_modal(true)

        local image_filter = Gtk.FileFilter.new()
        image_filter.set_name("Image files")
        foreach (mime in ["image/png", "image/jpeg", "image/webp", "image/gif", "image/svg+xml", "image/bmp", "image/tiff"]) {
            image_filter.add_mime_type(mime)
        }
        foreach (pattern in ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.gif", "*.svg", "*.bmp", "*.tif", "*.tiff"]) {
            image_filter.add_pattern(pattern)
        }
        dialog.add_filter(image_filter)

        local all_filter = Gtk.FileFilter.new()
        all_filter.set_name("All files")
        all_filter.add_pattern("*")
        dialog.add_filter(all_filter)

        dialog.connect("response", function(response) {
            if (response == Gtk.ResponseType.accept || response == Gtk.ResponseType.ok) {
                local file = dialog.get_file()
                if (file != null) {
                    local path = file.get_path()
                    if (path != null) {
                        local selected = this.document.selected()
                        if (selected != null && selected.type == "image") {
                            selected.path = path
                            this.refresh_inspector()
                            this.queue_preview()
                            this.set_status("Selected overlay image " + file.get_parse_name())
                        }
                    }
                }
            }
            dialog.destroy()
        }.bindenv(this))
        dialog.show()
    }

    function update_source_guidance() {
        if (this.source_kind_drop == null || this.source_value_row == null) return
        local kind = this.source_kind_values[this.source_kind_drop.get_selected()]
        local uses_value = kind != "test"
        this.source_value_row.set_visible(uses_value)
        if (this.source_browse_button != null) this.source_browse_button.set_visible(kind == "uri")
        if (this.loop_input_check != null) this.loop_input_check.set_visible(kind == "uri")
        this.source_pattern_row.set_visible(kind == "test")

        if (kind == "test") {
            this.source_pattern_entry.set_placeholder_text("smpte")
            this.source_pattern_help.set_text("Try smpte, ball, snow, black, white, red, green, blue, checkers-1, pinwheel. This is the safest way to test an output pipeline.")
        } else if (kind == "webcam") {
            this.source_value_label.set_text("Camera device")
            this.source_entry.set_placeholder_text("/dev/video0")
            this.source_value_help.set_text("Use a V4L2 camera path. On Linux this is usually /dev/video0, /dev/video1, and so on.")
        } else if (kind == "uri") {
            this.source_value_label.set_text("Media URI")
            this.source_entry.set_placeholder_text("file:///home/me/video.mp4, https://..., or rtsp://...")
            this.source_value_help.set_text("Use file:// for local media, http(s):// for network files, or rtsp:// for cameras and live feeds. Enable looping for finite, seekable files or HTTP media.")
        } else {
            this.source_value_label.set_text("GStreamer source chain")
            this.source_entry.set_placeholder_text("videotestsrc is-live=true pattern=smpte")
            this.source_value_help.set_text("Advanced mode: enter only the source side. The app appends conversion, crop/resize, cairooverlay, encoder, and output stages.")
        }
    }

    function update_output_guidance() {
        if (this.output_drop == null) return
        local kind = this.output_kind_values[this.output_drop.get_selected()]
        local is_live = kind == "youtube" || kind == "facebook"
        local uses_output_value = kind == "file" || kind == "custom" || is_live

        if (this.output_row != null) this.output_row.set_visible(uses_output_value)
        if (this.stream_key_row != null) this.stream_key_row.set_visible(is_live)
        this.set_panel_visible(this.udp_group, kind == "udp")
        this.set_panel_visible(this.encoding_group, kind == "file" || kind == "udp" || is_live)

        if (this.encoder_drop != null) this.encoder_drop.get_parent().set_visible(kind == "file")
        if (this.container_drop != null) this.container_drop.get_parent().set_visible(kind == "file")

        if (kind == "file") {
            this.output_label.set_text("Record file path")
            this.output_entry.set_placeholder_text("/tmp/telem-studio-preview.mkv")
        } else if (kind == "custom") {
            this.output_label.set_text("Custom GStreamer sink")
            this.output_entry.set_placeholder_text("fakesink sync=true")
        } else if (kind == "youtube") {
            this.output_label.set_text("YouTube server URL")
            this.output_entry.set_placeholder_text("rtmps://a.rtmps.youtube.com/live2")
            this.stream_key_label.set_text("YouTube stream key")
            this.stream_key_entry.set_placeholder_text("Paste stream key from YouTube Studio")
        } else if (kind == "facebook") {
            this.output_label.set_text("Facebook server URL")
            this.output_entry.set_placeholder_text("rtmps://live-api-s.facebook.com:443/rtmp")
            this.stream_key_label.set_text("Facebook stream key")
            this.stream_key_entry.set_placeholder_text("Paste stream key from Facebook Live Producer")
        }
    }

    function refresh_source_controls() {
        this.refreshing = true
        this.source_kind_drop.set_selected(index_of(this.source_kind_values, this.source_config.kind))
        this.source_entry.set_text(this.source_value_for_kind(this.source_config.kind))
        this.source_pattern_entry.set_text(this.source_config.test_pattern)
        this.width_adj.set_value(this.source_config.width)
        this.height_adj.set_value(this.source_config.height)
        this.fps_adj.set_value(this.source_config.fps)
        this.deinterlace_check.set_active(this.source_config.deinterlace)
        this.loop_input_check.set_active(this.source_config.loop_input)
        this.flip_drop.set_selected(index_of(this.flip_values, this.source_config.flip))
        this.crop_top_adj.set_value(this.source_config.crop_top)
        this.crop_bottom_adj.set_value(this.source_config.crop_bottom)
        this.crop_left_adj.set_value(this.source_config.crop_left)
        this.crop_right_adj.set_value(this.source_config.crop_right)

        this.output_drop.set_selected(index_of(this.output_kind_values, this.source_config.output_kind))
        this.output_entry.set_text(this.output_value_for_kind(this.source_config.output_kind))
        this.stream_key_entry.set_text(this.stream_key_for_kind(this.source_config.output_kind))
        this.output_host_entry.set_text(this.source_config.output_host)
        this.output_port_adj.set_value(this.source_config.output_port)
        this.encoder_drop.set_selected(index_of(this.encoder_values, this.source_config.video_encoder))
        this.container_drop.set_selected(index_of(this.container_values, this.source_config.container))
        this.bitrate_adj.set_value(this.source_config.bitrate_kbps)
        this.preset_entry.set_text(this.source_config.speed_preset)
        this.refreshing = false
        this.update_source_guidance()
        this.update_output_guidance()
    }

    function apply_source_controls() {
        if (this.refreshing || this.source_kind_drop == null) return
        local src_idx = this.source_kind_drop.get_selected()
        local new_kind = this.source_kind_values[src_idx]
        if (new_kind != this.source_config.kind) {
            this.source_config.kind = new_kind
            this.refreshing = true
            this.source_entry.set_text(this.source_value_for_kind(new_kind))
            this.refreshing = false
            this.update_source_guidance()
            this.set_status("Selected " + new_kind + " input")
            this.queue_preview()
            return
        }
        if (this.source_config.kind == "webcam") this.source_config.device = this.source_entry.get_text()
        else if (this.source_config.kind == "uri") this.source_config.uri = this.source_entry.get_text()
        else if (this.source_config.kind == "custom") this.source_config.custom_source = this.source_entry.get_text()
        this.source_config.test_pattern = this.source_pattern_entry.get_text()
        this.source_config.width = this.width_adj.get_value().tointeger()
        this.source_config.height = this.height_adj.get_value().tointeger()
        this.source_config.fps = this.fps_adj.get_value().tointeger()
        this.source_config.deinterlace = this.deinterlace_check.get_active()
        this.source_config.loop_input = this.loop_input_check.get_active()
        this.source_config.flip = this.flip_values[this.flip_drop.get_selected()]
        this.source_config.crop_top = this.crop_top_adj.get_value().tointeger()
        this.source_config.crop_bottom = this.crop_bottom_adj.get_value().tointeger()
        this.source_config.crop_left = this.crop_left_adj.get_value().tointeger()
        this.source_config.crop_right = this.crop_right_adj.get_value().tointeger()
        this.document.video_width = this.source_config.width.tofloat()
        this.document.video_height = this.source_config.height.tofloat()

        local new_output_kind = this.output_kind_values[this.output_drop.get_selected()]
        if (new_output_kind != this.source_config.output_kind) {
            this.source_config.output_kind = new_output_kind
            this.refreshing = true
            this.output_entry.set_text(this.output_value_for_kind(new_output_kind))
            this.stream_key_entry.set_text(this.stream_key_for_kind(new_output_kind))
            this.refreshing = false
            this.update_output_guidance()
            this.set_status("Selected " + new_output_kind + " output")
            this.queue_preview()
            return
        }

        if (this.source_config.output_kind == "custom") this.source_config.custom_sink = this.output_entry.get_text()
        else if (this.source_config.output_kind == "youtube") {
            this.source_config.youtube_server_url = this.output_entry.get_text()
            this.source_config.youtube_stream_key = this.stream_key_entry.get_text()
        } else if (this.source_config.output_kind == "facebook") {
            this.source_config.facebook_server_url = this.output_entry.get_text()
            this.source_config.facebook_stream_key = this.stream_key_entry.get_text()
        } else if (this.source_config.output_kind == "rtmp") this.source_config.stream_uri = this.output_entry.get_text()
        else if (this.source_config.output_kind == "file") this.source_config.output_path = this.output_entry.get_text()
        this.source_config.output_host = this.output_host_entry.get_text()
        this.source_config.output_port = this.output_port_adj.get_value().tointeger()
        this.source_config.video_encoder = this.encoder_values[this.encoder_drop.get_selected()]
        this.source_config.container = this.container_values[this.container_drop.get_selected()]
        this.source_config.bitrate_kbps = this.bitrate_adj.get_value().tointeger()
        this.source_config.speed_preset = this.preset_entry.get_text()
        this.update_source_guidance()
        this.update_output_guidance()
        this.set_status("Configured " + this.source_config.kind + " input -> " + this.source_config.output_kind)
        this.queue_preview()
    }

    function refresh_data_source_controls() {
        if (this.data_source_drop == null) return
        local src = this.data_sources.selected(this.data_source_drop.get_selected())
        if (src == null) return
        this.refreshing_data = true
        this.data_enabled_check.set_active(src.enabled)
        this.data_url_entry.set_text(src.url)
        this.data_host_entry.set_text(src.host)
        this.data_port_adj.set_value(src.port)
        this.data_interval_adj.set_value(src.interval_ms)
        this.data_payload_entry.set_text(src.payload)
        this.data_prefix_entry.set_text(src.prefix)
        this.data_url_entry.set_placeholder_text(src.kind == "http_post" ? "/telemetry" : "http://127.0.0.1:8080/telemetry.json")
        this.data_host_entry.set_placeholder_text(src.kind == "http" ? "remote host is part of the URL" : "127.0.0.1 or 0.0.0.0")
        this.data_payload_entry.set_placeholder_text(src.kind == "tcp" ? "telemetry\\n" : "")
        this.refreshing_data = false
    }

    function apply_data_source_controls() {
        if (this.refreshing_data || this.data_source_drop == null) return
        local src = this.data_sources.selected(this.data_source_drop.get_selected())
        if (src == null) return
        local was_udp = src.kind == "udp" && src.socket != null
        local was_http_post = src.kind == "http_post" && src.server != null
        src.enabled = this.data_enabled_check.get_active()
        src.url = this.data_url_entry.get_text()
        src.host = this.data_host_entry.get_text()
        src.port = this.data_port_adj.get_value().tointeger()
        src.interval_ms = this.data_interval_adj.get_value().tointeger()
        src.payload = this.data_payload_entry.get_text()
        src.prefix = this.data_prefix_entry.get_text()
        if (was_udp) {
            try { src.socket.close(null) } catch (_) {}
            src.socket = null
        }
        if (was_http_post) {
            try { src.server.disconnect() } catch (_) {}
            src.server = null
        }
        if (src.enabled && src.kind == "udp") this.data_sources.ensure_udp(src)
        if (src.enabled && src.kind == "http_post") this.data_sources.ensure_http_post(src)
        this.refresh_live_labels()
    }

    function set_status(text) {
        if (this.status_label != null) this.status_label.set_text(text)
        if (this.start_button != null) this.start_button.set_sensitive(this.pipeline.pipe == null && !this.pipeline.stopping)
        if (this.stop_button != null) this.stop_button.set_sensitive(this.pipeline.pipe != null && !this.pipeline.stopping)
    }

    function queue_preview() {
        if (this.preview != null) this.preview.queue_draw()
    }

    function refresh_live_labels() {
        if (this.telemetry_label != null) {
            this.telemetry_label.set_text(this.telemetry.summary() + "\n" + this.data_sources.summary())
        }
    }

    function rebuild_overlay_list() {
        if (this.overlay_list == null) return
        while (true) {
            local row = this.overlay_list.get_row_at_index(0)
            if (row == null) break
            this.overlay_list.remove(row)
        }
        foreach (item in this.document.items) {
            local row = Gtk.ListBoxRow.new()
            local label = Gtk.Label.new(format("%s  (%s)", item.name, item.type))
            label.set_xalign(0.0)
            label.set_margin_top(8)
            label.set_margin_bottom(8)
            label.set_margin_start(8)
            label.set_margin_end(8)
            row.set_child(label)
            this.overlay_list.append(row)
            if (item.id == this.document.selected_id) this.overlay_list.select_row(row)
        }
    }

    function refresh_inspector() {
        if (this.enabled_check == null) return
        local item = this.document.selected()
        if (item == null) return
        this.refreshing = true
        this.enabled_check.set_active(item.enabled)
        this.name_entry.set_text(item.name)
        this.text_entry.set_text(item.text)
        if (this.field_label != null) this.field_label.set_text(item.type == "image" ? "Image file" : "Data field")
        if (this.field_browse_button != null) this.field_browse_button.set_visible(item.type == "image")
        this.field_entry.set_text(item.type == "image" ? item.path : item.field)
        this.field_entry.set_editable(item.type != "image")
        this.field_entry.set_placeholder_text(item.type == "image" ? "Choose an image file" : "speed, heading, lap, or another telemetry field")
        this.prefix_entry.set_text(item.prefix)
        this.suffix_entry.set_text(item.suffix)
        this.x_adj.set_value(item.x)
        this.y_adj.set_value(item.y)
        this.w_adj.set_value(item.width)
        this.h_adj.set_value(item.height)
        this.scale_adj.set_value(item.scale)
        this.rotation_adj.set_value(item.rotation)
        this.opacity_adj.set_value(item.opacity)
        this.font_entry.set_text(item.font_family)
        this.font_adj.set_value(item.font_size)
        this.padding_adj.set_value(item.padding)
        this.radius_adj.set_value(item.radius)
        this.decimals_adj.set_value(item.decimals)
        this.align_drop.set_selected(index_of(this.align_values, item.align))
        this.fit_drop.set_selected(index_of(this.fit_values, item.fit))
        this.bold_check.set_active(item.bold)
        this.italic_check.set_active(item.italic)
        this.shadow_check.set_active(item.shadow)
        this.fill_entry.set_text(color_to_hex(item.fill))
        this.stroke_entry.set_text(color_to_hex(item.stroke))
        this.text_color_entry.set_text(color_to_hex(item.text_color))
        this.refreshing = false
    }

    function apply_inspector() {
        if (this.refreshing) return
        local item = this.document.selected()
        if (item == null || this.name_entry == null) return

        local new_name = this.name_entry.get_text()
        local renamed = item.name != new_name
        item.enabled = this.enabled_check.get_active()
        item.name = new_name
        item.text = this.text_entry.get_text()
        if (item.type == "image") item.path = this.field_entry.get_text()
        else item.field = this.field_entry.get_text()
        item.prefix = this.prefix_entry.get_text()
        item.suffix = this.suffix_entry.get_text()
        item.x = this.x_adj.get_value()
        item.y = this.y_adj.get_value()
        item.width = this.w_adj.get_value()
        item.height = this.h_adj.get_value()
        item.scale = this.scale_adj.get_value()
        item.rotation = this.rotation_adj.get_value()
        item.opacity = this.opacity_adj.get_value()
        item.font_family = this.font_entry.get_text()
        item.font_size = this.font_adj.get_value()
        item.padding = this.padding_adj.get_value()
        item.radius = this.radius_adj.get_value()
        item.decimals = this.decimals_adj.get_value().tointeger()
        item.align = this.align_values[this.align_drop.get_selected()]
        item.fit = this.fit_values[this.fit_drop.get_selected()]
        item.bold = this.bold_check.get_active()
        item.italic = this.italic_check.get_active()
        item.shadow = this.shadow_check.get_active()
        item.fill = parse_color(this.fill_entry.get_text(), item.fill)
        item.stroke = parse_color(this.stroke_entry.get_text(), item.stroke)
        item.text_color = parse_color(this.text_color_entry.get_text(), item.text_color)

        if (renamed) this.rebuild_overlay_list()
        this.queue_preview()
    }

    function add_item(kind) {
        if (kind == "text") this.document.add_text()
        else if (kind == "telemetry") this.document.add_telemetry_text("Heading", "heading")
        else if (kind == "score") this.document.add_scorebug()
        else if (kind == "image") this.document.add_image_placeholder()
        else if (kind == "timer") this.document.add_timer()
        else this.document.add_shape()

        this.rebuild_overlay_list()
        this.refresh_inspector()
        this.queue_preview()
        if (kind == "image") this.open_image_overlay_dialog()
    }

    function start_pipeline() {
        this.apply_source_controls()
        this.pipeline.start()
        if (this.pipeline.pipe == null) {
            this.set_status("Pipeline did not start")
        } else if (this.source_config.output_kind == "process") {
            this.set_status("Running in process-only mode. The editor is showing the live source preview with editable overlays.")
        } else {
            this.set_status("Running: " + this.source_config.kind + " -> " + this.source_config.output_kind)
        }
    }

    function stop_pipeline() {
        this.pipeline.stop()
    }
}

return {
    StudioApp = StudioApp
}
