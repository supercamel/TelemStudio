local Gst = import("Gst")
Gst.init(null)

local GLib = import("GLib")
local T = import("lib/telemetry.nut")
local D = import("lib/overlay_document.nut")
local R = import("lib/overlay_renderer.nut")
local P = import("lib/pipeline_controller.nut")
local A = import("lib/studio_app.nut")
local DS = import("lib/data_sources.nut")
local PF = import("lib/project_file.nut")

function usage() {
    print("Usage:\n")
    print("  sqgi main.nut                         Start the GTK editor\n")
    print("  sqgi main.nut --headless PROJECT      Run a saved project in the terminal\n")
    print("  sqgi main.nut --headless PROJECT --duration=SECONDS\n")
    print("  sqgi main.nut --headless PROJECT --youtube-key=KEY\n")
    print("  sqgi main.nut --headless PROJECT --facebook-key=KEY\n")
    print("  TELEMSTUDIO_YOUTUBE_STREAM_KEY and TELEMSTUDIO_FACEBOOK_STREAM_KEY are also supported\n")
    print("  sqgi main.nut --smoke                 Render a short internal pipeline test\n")
}

function arg_value(prefix, fallback = "") {
    foreach (arg in vargv) {
        if (arg.find(prefix) == 0) return arg.slice(prefix.len())
    }
    return fallback
}

function env_value(name, fallback = "") {
    local value = GLib.getenv(name)
    return value != null ? value : fallback
}

function apply_headless_secrets(source) {
    source.youtube_stream_key = arg_value("--youtube-key=",
        env_value("TELEMSTUDIO_YOUTUBE_STREAM_KEY", ""))
    source.facebook_stream_key = arg_value("--facebook-key=",
        env_value("TELEMSTUDIO_FACEBOOK_STREAM_KEY", ""))

    if (source.output_kind == "youtube" && source.youtube_stream_key.len() == 0) {
        print("YouTube headless output requires --youtube-key=KEY or TELEMSTUDIO_YOUTUBE_STREAM_KEY\n")
        return false
    }
    if (source.output_kind == "facebook" && source.facebook_stream_key.len() == 0) {
        print("Facebook headless output requires --facebook-key=KEY or TELEMSTUDIO_FACEBOOK_STREAM_KEY\n")
        return false
    }
    return true
}

function run_headless(project_path, duration_s = 0) {
    local telemetry = T.TelemetryStore()
    local loaded = PF.load_project(project_path)
    if (!apply_headless_secrets(loaded.source)) return 1
    local data_sources = DS.DataSourceManager(telemetry)
    PF.apply_data_sources(data_sources, loaded.data_sources)
    local renderer = R.OverlayRenderer(loaded.document, telemetry)
    local pipeline = P.PipelineController(loaded.document, renderer, loaded.source)
    local loop = GLib.MainLoop.new(null, false)
    local exit_code = 0

    pipeline.set_status_callback(function(text) {
        print(text + "\n")
        if (text.find("Pipeline error:") == 0) exit_code = 1
    })

    data_sources.start()
    pipeline.start()
    if (pipeline.pipe == null) {
        data_sources.stop()
        return 1
    }

    sqgi.timeout_add(100, function() {
        data_sources.tick()
        pipeline.poll_bus()
        if (pipeline.pipe == null) {
            data_sources.stop()
            loop.quit()
            return false
        }
        return true
    })

    if (duration_s > 0) {
        sqgi.timeout_add(duration_s * 1000, function() {
            print("Headless duration elapsed\n")
            pipeline.stop()
            data_sources.stop()
            loop.quit()
            return false
        })
    }

    print("Headless project running: " + project_path + "\n")
    loop.run()
    data_sources.stop()
    if (pipeline.pipe != null) pipeline.finish_stop("Stopped")
    return exit_code
}

foreach (arg in vargv) {
    if (arg == "--help" || arg == "-h") {
        usage()
        return 0
    }
    if (arg == "--smoke") {
        local telemetry = T.TelemetryStore()
        telemetry.merge({
            speed = 72.0,
            altitude = 120.0,
            heading = 28.0,
            home_score = 2,
            away_score = 1,
            status = "smoke"
        })

        local document = D.OverlayDocument()
        local renderer = R.OverlayRenderer(document, telemetry)
        local source = P.VideoSourceConfig()
        local pipeline = P.PipelineController(document, renderer, source)
        return pipeline.smoke(12)
    }
}

for (local i = 0; i < vargv.len(); i += 1) {
    if (vargv[i] == "--headless" || vargv[i] == "--run") {
        if (i + 1 >= vargv.len()) {
            usage()
            return 1
        }
        local duration_s = 0
        for (local j = 0; j < vargv.len(); j += 1) {
            if (vargv[j].find("--duration=") == 0) duration_s = vargv[j].slice(11).tointeger()
        }
        return run_headless(vargv[i + 1], duration_s)
    }
}

local app = A.StudioApp()
local status = app.run(0, null)
print("Application exited with status " + status + "\n")
