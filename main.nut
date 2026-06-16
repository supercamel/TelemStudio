local Gst = import("Gst")
Gst.init(null)

local T = import("lib/telemetry.nut")
local D = import("lib/overlay_document.nut")
local R = import("lib/overlay_renderer.nut")
local P = import("lib/pipeline_controller.nut")
local A = import("lib/studio_app.nut")

foreach (arg in vargv) {
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

local app = A.StudioApp()
local status = app.run(0, null)
print("Application exited with status " + status + "\n")
