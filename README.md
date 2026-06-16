# TelemStudio

TelemStudio is a desktop overlay studio for live video. It lets you place
score bugs, labels, telemetry values, timers, panels, and images over a video
source, then preview, record, or stream the finished output.

It is aimed at people who need practical live graphics without building a whole
broadcast stack: telemetry overlays for vehicles and experiments, scoreboard
layouts, stream graphics, simple production slates, and branded panels.

## What You Can Do

- Use a test pattern, webcam, media URI, or custom GStreamer source as input.
- Drag overlays directly on the preview canvas.
- Add text, telemetry fields, score bugs, timers, panels, and image overlays.
- Pick image overlays with a file chooser.
- Connect live data from HTTP JSON polling, an HTTP JSON POST endpoint, TCP, or UDP.
- Record to a file, stream MPEG-TS over UDP, or stream to YouTube Live/Facebook Live.
- Save and load project files.
- Run a saved project from the terminal in headless mode.

## Getting TelemStudio

Release builds are produced by GitHub Actions when a version tag is pushed.
The release assets are:

- `TelemStudio-x86_64.AppImage` for Linux PCs.
- `TelemStudio-aarch64.AppImage` for ARM64 Linux devices.
- `TelemStudio-Setup.exe` for Windows.

On Linux, download the AppImage, make it executable, and run it:

```bash
chmod +x TelemStudio-x86_64.AppImage
./TelemStudio-x86_64.AppImage
```

## Basic Workflow

1. Open TelemStudio.
2. Choose an input on the `Input` tab.
3. Add overlay layers on the `Layers` tab.
4. Select a layer and edit its position, size, colors, text, field name, or image.
5. Pick an output destination on the `Output` tab.
6. Press `Start`.

The preview canvas is editable. Click an overlay to select it, drag it to move
it, drag edge/corner handles to resize it, and use the top handle to rotate it.

## Video Input

The `Input` tab supports:

- `Test pattern`: good for setup and pipeline testing.
- `Webcam`: usually `/dev/video0` on Linux.
- `URI / file / HTTP / RTSP`: local files, HTTP media, RTSP cameras, and similar sources.
- `Custom GStreamer source`: advanced mode for custom capture chains.

The canvas width, height, and FPS are configured in the same tab. These values
define the coordinate system for overlays and the output video format.

## Overlays

Use the `Layers` tab to add:

- `Text`: static text.
- `Data`: a telemetry-driven text field.
- `Score`: a simple score bug.
- `Box`: a panel/graphic rectangle.
- `Image`: an image file overlay.
- `Timer`: a running clock.

Select a layer to edit it in the inspector. Image layers use a normal file
chooser, and the selected file path is displayed in the inspector.

## Live Data

The `Data` tab connects external values to telemetry overlays. A data overlay
shows the field named in its `Data field` setting.

Supported data sources:

- `HTTP JSON poll`: repeatedly GET a JSON endpoint.
- `HTTP JSON POST endpoint`: listen locally so other apps can POST JSON into TelemStudio.
- `TCP text/json poll`: connect to a TCP service and read a payload.
- `UDP text/json listener`: listen for UDP packets.

JSON payloads are flattened into dot-separated field names. For example:

```json
{
  "vehicle": {
    "speed": 72.4
  },
  "heading": 183
}
```

creates fields named `vehicle.speed` and `heading`.

Simple key/value text is also accepted:

```text
speed=72.4
heading=183
status=armed
```

## Output

Output options are shown only when relevant:

- `Process only`: run the overlay pipeline without opening an output video window.
- `Preview window`: show the final video in a normal video sink.
- `Record file`: write to a local file.
- `YouTube Live`: stream RTMP/RTMPS using YouTube server URL and stream key.
- `Facebook Live`: stream RTMP/RTMPS using Facebook server URL and stream key.
- `UDP MPEG-TS`: stream MPEG-TS to a host and port.
- `Custom sink`: advanced GStreamer sink chain.

YouTube and Facebook outputs use H.264 video plus AAC audio in an FLV/RTMP
stream. When the input URI has audio, TelemStudio carries that audio into the
stream. Sources without audio use a silent track for platform compatibility.

## Stream Keys

For normal encoder workflows, YouTube and Facebook use a stream server URL plus
a stream key. TelemStudio does not need an API key for that.

In the desktop app, paste the stream key into the platform output settings.

For headless mode, do not store stream keys in project files. Pass them at run
time:

```bash
sqgi main.nut --headless show.telemstudio --youtube-key=YOUR_KEY
sqgi main.nut --headless show.telemstudio --facebook-key=YOUR_KEY
```

or use environment variables:

```bash
TELEMSTUDIO_YOUTUBE_STREAM_KEY=YOUR_KEY sqgi main.nut --headless show.telemstudio
TELEMSTUDIO_FACEBOOK_STREAM_KEY=YOUR_KEY sqgi main.nut --headless show.telemstudio
```

## Save And Load

Use `Save`, `Save As`, and `Open` from the header bar.

Project files are JSON files and normally use the `.telemstudio` extension.
They store:

- overlay layout and styling
- video input/output settings
- data-source configuration

Headless stream keys are intentionally not stored in project files.

## Headless Mode

Headless mode runs a saved project in the terminal:

```bash
sqgi main.nut --headless show.telemstudio
```

For test runs, stop after a fixed number of seconds:

```bash
sqgi main.nut --headless show.telemstudio --duration=30
```

Headless mode is useful for startup scripts, remote machines, and systems where
the editor is used only to design the project.

## Notes For Advanced Users

TelemStudio is built on GTK 4 and GStreamer. Custom input and output fields are
GStreamer pipeline fragments, so they can be used to integrate unusual capture
devices, transport protocols, or sinks.

The project is packaged with `sqgipkg` for Linux AppImage and Windows NSIS
installer builds.
