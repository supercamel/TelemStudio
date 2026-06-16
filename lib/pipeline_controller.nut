local GLib = import("GLib")
local Gst = import("Gst")

class VideoSourceConfig {
    kind = "test"
    device = "/dev/video0"
    uri = ""
    custom_source = "videotestsrc is-live=true pattern=smpte"
    test_pattern = "smpte"
    width = 1280
    height = 720
    fps = 30
    crop_top = 0
    crop_bottom = 0
    crop_left = 0
    crop_right = 0
    flip = "none"
    deinterlace = false
    loop_input = false
    output_kind = "process"
    output_path = "/tmp/telem-studio-preview.mkv"
    output_host = "127.0.0.1"
    output_port = 5000
    stream_uri = "rtmp://127.0.0.1/live/telem"
    youtube_server_url = "rtmps://a.rtmps.youtube.com/live2"
    youtube_stream_key = ""
    facebook_server_url = "rtmps://live-api-s.facebook.com:443/rtmp"
    facebook_stream_key = ""
    container = "matroska"
    video_encoder = "x264"
    bitrate_kbps = 4000
    speed_preset = "veryfast"
    custom_sink = "fakesink sync=true"
}

class PipelineController {
    document = null
    renderer = null
    source = null
    pipe = null
    bus = null
    overlay = null
    preview_sink = null
    draw_handler_id = null
    frames = 0
    started_us = 0
    status_cb = null
    stopping = false
    stop_generation = 0

    constructor(document, renderer, source_config) {
        this.document = document
        this.renderer = renderer
        this.source = source_config
    }

    function set_status_callback(cb) {
        this.status_cb = cb
    }

    function status(text) {
        if (this.status_cb != null) this.status_cb(text)
    }

    function source_element_description(num_buffers = 0) {
        if (this.source.kind == "webcam") {
            return "v4l2src device=" + this.source.device
        }
        if (this.source.kind == "uri" && this.source.uri.len() > 0) {
            return "uridecodebin uri=" + this.source.uri
        }
        if (this.source.kind == "custom" && this.source.custom_source.len() > 0) {
            return this.source.custom_source
        }
        local opts = num_buffers > 0 ? ("num-buffers=" + num_buffers + " is-live=false ") : "is-live=true "
        return "videotestsrc " + opts + "pattern=" + this.source.test_pattern
    }

    function video_processing_description(src) {
        local caps = "video/x-raw,format=BGRA,width=" + this.source.width +
            ",height=" + this.source.height + ",framerate=" + this.source.fps + "/1"

        local chain = src + " ! queue ! videoconvert"
        if (this.source.deinterlace) chain += " ! deinterlace"
        if (this.source.crop_top > 0 || this.source.crop_bottom > 0 ||
            this.source.crop_left > 0 || this.source.crop_right > 0) {
            chain += " ! videocrop top=" + this.source.crop_top +
                " bottom=" + this.source.crop_bottom +
                " left=" + this.source.crop_left +
                " right=" + this.source.crop_right
        }
        if (this.source.flip != "none") chain += " ! videoflip method=" + this.source.flip
        return chain + " ! videorate ! videoscale ! " + caps
    }

    function source_description(num_buffers = 0) {
        return this.video_processing_description(this.source_element_description(num_buffers))
    }

    function encoder_description() {
        if (this.source.video_encoder == "vp8") {
            return "vp8enc deadline=1 target-bitrate=" + (this.source.bitrate_kbps * 1000)
        }
        if (this.source.video_encoder == "jpeg") {
            return "jpegenc quality=90"
        }
        return "x264enc tune=zerolatency speed-preset=" + this.source.speed_preset +
            " bitrate=" + this.source.bitrate_kbps + " key-int-max=" + (this.source.fps * 2)
    }

    function live_video_encoder_description() {
        return "x264enc pass=cbr tune=zerolatency speed-preset=" + this.source.speed_preset +
            " bitrate=" + this.source.bitrate_kbps + " key-int-max=" + (this.source.fps * 2) +
            " ! video/x-h264,profile=high ! h264parse config-interval=1"
    }

    function aac_encoder_description() {
        if (Gst.ElementFactory.find("voaacenc") != null) return "voaacenc bitrate=128000"
        return "avenc_aac bitrate=128000"
    }

    function audio_encoder_description() {
        if (this.source.container == "webm") return "opusenc bitrate=128000"
        return this.aac_encoder_description() + " ! aacparse"
    }

    function decoded_audio_to_mux_description(src, mux_name) {
        return src + " ! queue ! audioconvert ! audioresample ! audio/x-raw,rate=44100,channels=2 ! " +
            this.audio_encoder_description() + " ! queue ! " + mux_name + "."
    }

    function silent_audio_to_mux_description(mux_name) {
        return "audiotestsrc is-live=true wave=silence ! audioconvert ! audioresample ! " +
            "audio/x-raw,rate=44100,channels=2 ! " + this.aac_encoder_description() +
            " ! aacparse ! queue ! " + mux_name + "."
    }

    function live_rtmp_sink_description() {
        return this.live_video_encoder_description() + " ! queue ! live_mux. " +
            this.silent_audio_to_mux_description("live_mux") + " " +
            "flvmux name=live_mux streamable=true ! rtmpsink location=" + this.live_stream_location()
    }

    function live_rtmp_sink_with_audio_description(audio_src) {
        return this.live_video_encoder_description() + " ! queue ! live_mux. " +
            this.decoded_audio_to_mux_description(audio_src, "live_mux") + " " +
            "flvmux name=live_mux streamable=true ! rtmpsink location=" + this.live_stream_location()
    }

    function live_stream_location() {
        if (this.source.output_kind == "youtube") {
            return this.combine_stream_url(this.source.youtube_server_url, this.source.youtube_stream_key)
        }
        if (this.source.output_kind == "facebook") {
            return this.combine_stream_url(this.source.facebook_server_url, this.source.facebook_stream_key)
        }
        return this.source.stream_uri
    }

    function combine_stream_url(server_url, stream_key) {
        if (stream_key.len() == 0) return server_url
        if (server_url.len() == 0) return stream_key
        return server_url + (server_url.slice(server_url.len() - 1) == "/" ? "" : "/") + stream_key
    }

    function is_live_platform_output() {
        return this.source.output_kind == "youtube" || this.source.output_kind == "facebook" ||
            this.source.output_kind == "rtmp"
    }

    function muxer_description() {
        if (this.source.container == "mp4") return "mp4mux faststart=true"
        if (this.source.container == "webm") return "webmmux"
        if (this.source.container == "mpegts") return "mpegtsmux"
        return "matroskamux"
    }

    function sink_description() {
        if (this.source.output_kind == "preview") {
            return "autovideosink sync=false"
        }
        if (this.source.output_kind == "file") {
            return this.encoder_description() + " ! " + this.muxer_description() +
                " ! filesink location=" + this.source.output_path
        }
        if (this.is_live_platform_output()) {
            return this.live_rtmp_sink_description()
        }
        if (this.source.output_kind == "udp") {
            return this.encoder_description() + " ! h264parse ! mpegtsmux ! udpsink host=" +
                this.source.output_host + " port=" + this.source.output_port
        }
        if (this.source.output_kind == "custom" && this.source.custom_sink.len() > 0) {
            return this.source.custom_sink
        }
        return "fakesink sync=true"
    }

    function sink_with_decoded_audio_description(audio_src) {
        if (this.source.output_kind == "file") {
            return this.encoder_description() + " ! queue ! file_mux. " +
                this.decoded_audio_to_mux_description(audio_src, "file_mux") + " " +
                this.muxer_description() + " name=file_mux ! filesink location=" + this.source.output_path
        }
        if (this.is_live_platform_output()) {
            return this.live_rtmp_sink_with_audio_description(audio_src)
        }
        if (this.source.output_kind == "udp") {
            return this.encoder_description() + " ! h264parse ! queue ! udp_mux. " +
                this.decoded_audio_to_mux_description(audio_src, "udp_mux") + " " +
                "mpegtsmux name=udp_mux ! udpsink host=" +
                this.source.output_host + " port=" + this.source.output_port
        }
        return this.sink_description()
    }

    function live_platform_ready() {
        if (this.source.output_kind == "youtube") {
            if (this.source.youtube_server_url.len() == 0 || this.source.youtube_stream_key.len() == 0) {
                this.status("YouTube Live needs a server URL and stream key")
                return false
            }
        }
        if (this.source.output_kind == "facebook") {
            if (this.source.facebook_server_url.len() == 0 || this.source.facebook_stream_key.len() == 0) {
                this.status("Facebook Live needs a server URL and stream key")
                return false
            }
        }
        return true
    }

    function preview_sink_description() {
        return "videoconvert ! video/x-raw,format=RGB,width=" + this.source.width +
            ",height=" + this.source.height + ",framerate=" + this.source.fps +
            "/1 ! gdkpixbufsink name=preview_sink sync=false qos=false max-lateness=-1"
    }

    function build(num_buffers = 0) {
        local desc = ""
        if (this.source.kind == "uri" && this.source.uri.len() > 0 &&
            (this.source.output_kind == "file" || this.source.output_kind == "udp" ||
             this.is_live_platform_output())) {
            desc = "uridecodebin name=input_decode uri=" + this.source.uri + " " +
                this.video_processing_description("input_decode.") +
                " ! tee name=source_tee " +
                "source_tee. ! queue leaky=downstream max-size-buffers=2 ! " + this.preview_sink_description() + " " +
                "source_tee. ! queue ! videoconvert ! cairooverlay name=overlay ! videoconvert ! " +
                this.sink_with_decoded_audio_description("input_decode.")
        } else {
            desc = this.source_description(num_buffers) +
            " ! tee name=source_tee " +
            "source_tee. ! queue leaky=downstream max-size-buffers=2 ! " + this.preview_sink_description() + " " +
            "source_tee. ! queue ! videoconvert ! cairooverlay name=overlay ! videoconvert ! " +
            this.sink_description()
        }

        local p = Gst.parse_launch(desc)
        if (p == null) return null

        this.preview_sink = p.get_by_name("preview_sink")
        local overlay = p.get_by_name("overlay")
        this.overlay = overlay
        this.draw_handler_id = overlay.connect("draw", function(cr, ts_ns, dur_ns) {
            if (this.stopping) return
            this.frames += 1
            this.renderer.draw(cr, this.source.width.tofloat(), this.source.height.tofloat(),
                ts_ns / 1000000000.0, null)
        }.bindenv(this))
        return p
    }

    function start() {
        if (this.pipe != null || this.stopping) return
        if (Gst.ElementFactory.find("cairooverlay") == null) {
            this.status("Missing GStreamer cairooverlay element")
            return
        }
        if (Gst.ElementFactory.find("gdkpixbufsink") == null) {
            this.status("Missing GStreamer gdkpixbufsink element")
            return
        }
        if (this.is_live_platform_output()) {
            if (!this.live_platform_ready()) return
            foreach (name in ["x264enc", "h264parse", "flvmux", "rtmpsink", "audiotestsrc", "aacparse"]) {
                if (Gst.ElementFactory.find(name) == null) {
                    this.status("Missing GStreamer " + name + " element for YouTube/Facebook RTMP output")
                    return
                }
            }
            if (Gst.ElementFactory.find("voaacenc") == null && Gst.ElementFactory.find("avenc_aac") == null) {
                this.status("Missing GStreamer AAC encoder for YouTube/Facebook RTMP output")
                return
            }
        }

        this.frames = 0
        this.started_us = GLib.get_monotonic_time()
        this.stopping = false
        this.pipe = this.build()
        if (this.pipe == null) {
            this.status("Could not create pipeline")
            return
        }

        this.bus = this.pipe.get_bus()
        this.pipe.set_state(Gst.State.playing)
        this.status("Pipeline running: " + this.source.kind + " -> cairooverlay -> " + this.source.output_kind)
    }

    function stop() {
        this.request_stop()
    }

    function disconnect_draw() {
        if (this.overlay != null && this.draw_handler_id != null) {
            try { this.overlay.disconnect(this.draw_handler_id) } catch (_) {}
        }
        this.overlay = null
        this.draw_handler_id = null
    }

    function preview_pixbuf() {
        if (this.preview_sink == null) return null
        try { return this.preview_sink.get_property("last-pixbuf") } catch (_) {}
        return null
    }

    function should_loop_on_eos() {
        return this.source.loop_input && this.source.kind == "uri"
    }

    function loop_to_start() {
        if (this.pipe == null) return false
        try {
            local ok = this.pipe.seek_simple(Gst.Format.time,
                Gst.SeekFlags.flush + Gst.SeekFlags.key_unit, 0)
            if (ok) {
                this.started_us = GLib.get_monotonic_time()
                this.status("Looped input from start")
                return true
            }
        } catch (_) {}
        this.status("Input reached the end and could not be looped")
        return false
    }

    function request_stop() {
        if (this.pipe == null) return
        if (this.stopping) return
        this.stopping = true
        this.stop_generation += 1
        local gen = this.stop_generation
        this.status("Stopping pipeline...")
        this.disconnect_draw()
        sqgi.timeout_add(50, function() {
            if (gen == this.stop_generation) this.finish_stop("Stopped")
            return false
        }.bindenv(this))
    }

    function finish_stop(prefix = "Stopped") {
        if (this.pipe == null) {
            this.stopping = false
            return
        }
        this.disconnect_draw()
        local old_pipe = this.pipe
        local frame_count = this.frames
        this.pipe = null
        this.bus = null
        this.preview_sink = null
        this.started_us = 0
        old_pipe.set_state(Gst.State["null"])
        this.stopping = false
        this.status(format("%s after %d rendered frames", prefix, frame_count))
    }

    function poll_bus() {
        if (this.bus == null) return true
        local mask = Gst.MessageType.eos + Gst.MessageType.error + Gst.MessageType.warning
        while (true) {
            local msg = this.bus.timed_pop_filtered(0, mask)
            if (msg == null) break
            if (msg.type == Gst.MessageType.error) {
                local r = msg.parse_error()
                this.status("Pipeline error: " + r[0])
                this.finish_stop("Stopped")
                break
            }
            if (msg.type == Gst.MessageType.eos) {
                if (this.should_loop_on_eos() && this.loop_to_start()) {
                    break
                }
                this.finish_stop("Stopped")
                break
            }
        }
        return true
    }

    function smoke(frames_to_render) {
        this.pipe = this.build(frames_to_render)
        if (this.pipe == null) {
            print("smoke: could not build pipeline\n")
            return 1
        }

        this.bus = this.pipe.get_bus()
        this.pipe.set_state(Gst.State.playing)

        local ctx = GLib.MainContext.default()
        local mask = Gst.MessageType.eos + Gst.MessageType.error
        local code = 0
        local done = false
        while (!done) {
            while (ctx.iteration(false)) {}
            local msg = this.bus.timed_pop_filtered(100 * 1000 * 1000, mask)
            if (msg == null) continue
            if (msg.type == Gst.MessageType.eos) done = true
            else if (msg.type == Gst.MessageType.error) {
                local r = msg.parse_error()
                print("smoke error: " + r[0] + "\n")
                code = 1
                done = true
            }
        }
        while (ctx.iteration(false)) {}
        this.disconnect_draw()
        this.pipe.set_state(Gst.State["null"])
        this.preview_sink = null
        print(format("smoke: drew %d frames\n", this.frames))
        return code
    }
}

return {
    VideoSourceConfig = VideoSourceConfig,
    PipelineController = PipelineController
}
