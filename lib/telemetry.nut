local GLib = import("GLib")

class TelemetryStore {
    values = null
    updated_us = 0

    constructor() {
        this.values = {
            speed = 0.0,
            altitude = 120.0,
            heading = 0.0,
            home_score = 2,
            away_score = 1,
            home_label = "HOME",
            away_label = "AWAY",
            status = "idle"
        }
        this.updated_us = GLib.get_monotonic_time()
    }

    function set_value(key, value) {
        this.values[key] <- value
        this.updated_us = GLib.get_monotonic_time()
    }

    function merge(update) {
        foreach (k, v in update) this.values[k] <- v
        this.updated_us = GLib.get_monotonic_time()
    }

    function get_value(key, fallback = "") {
        return key in this.values ? this.values[key] : fallback
    }

    function snapshot() {
        local out = {}
        foreach (k, v in this.values) out[k] <- v
        out.updated_us <- this.updated_us
        return out
    }

    function summary() {
        return format("Telemetry: %.1f km/h  %.0f m  %.0f deg  %d-%d",
            this.get_value("speed", 0.0),
            this.get_value("altitude", 0.0),
            this.get_value("heading", 0.0),
            this.get_value("home_score", 0),
            this.get_value("away_score", 0))
    }
}

return {
    TelemetryStore = TelemetryStore
}
