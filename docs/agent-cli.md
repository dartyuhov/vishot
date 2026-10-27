# Agent CLI

The compiled CLI bundled with Vishot lists and captures live app windows without
moving or activating them. It also annotates existing local PNGs, optionally
opening the saved result in the default image app. Run the executable in your
installed app (adjust the app path to match your installation):

```sh
~/Applications/Vishot.app/Contents/Helpers/vishot windows
~/Applications/Vishot.app/Contents/Helpers/vishot capture --window-id 42
~/Applications/Vishot.app/Contents/Helpers/vishot --version
```

The CLI runs on macOS 14 or newer without a development runtime. It ships in
the app's native architecture and reads the app's release version. A symlink
to the bundled executable also works. The app location comes from the
resolved executable path, so multiple installations have separate endpoints.
Fonts and release metadata come from that same installation, including when
its path contains spaces or your working directory is elsewhere. The working
directory selects output storage, not app resources.

For agents, the repository includes a [capture skill](../skills/vishot-capture/SKILL.md)
covering exact-ID selection, immediate image reading, and annotation of the same
captured PNG. The optional external installation command and Setup/Settings
integration are documented in
[agent skill installation](agent-skill-integration.md).

## Discovery JSON

`vishot windows` writes one UTF-8 JSON object followed by a newline to stdout.
Success exits with status 0. Diagnostics never precede or follow that object.

```json
{"schemaVersion":1,"ok":true,"windows":[{"id":42,"app":{"pid":123,"bundleID":"com.example.Editor","name":"Editor"},"title":"Document","bounds":{"x":-800,"y":30,"width":800,"height":600}}]}
```

Window IDs are exact live CoreGraphics IDs, not durable identities. Windows
are sorted by numeric ID, not front-to-back order. The app identity includes
its process ID, localized name, and bundle identifier when available. An
unknown bundle identifier is omitted. Untitled windows have an empty title.

Bounds use CoreGraphics global coordinates in **points**, with the origin at
the primary display's top-left and y increasing downward. Displays to the
left or above can produce negative coordinates. Bounds are not image pixel
dimensions.

Discovery includes fully covered windows and offscreen windows reported by
macOS, including best-effort windows in other Spaces. It does not test visible
area or switch Spaces. It excludes Vishot, non-regular apps, nonzero window
layers, transparent windows, and empty frames. Minimized or stale windows may
be absent; discovery does not promise that every listed window is capturable.
The interactive picker keeps its own visible-area filtering.

## Capture JSON and files

Use an exact live ID from discovery. `vishot capture --window-id 42` captures
only that window's own content, not a crop of visible display pixels. A
successful command returns this envelope:

```json
{"schemaVersion":1,"ok":true,"capture":{"path":"/workspace/.vishot/window-42-9ab68a91-631e-4497-b28b-c19a3f06692a.png","target":{"id":42,"app":{"pid":123,"bundleID":"com.example.Editor","name":"Editor"},"title":"Document","bounds":{"x":-800,"y":30,"width":800,"height":600}},"width":1600,"height":1200}}
```

`width` and `height` are **image pixels**; `target.bounds` remains in points.
The target metadata comes from the capture-time window. The absolute `path`
is readable as a complete PNG before exit 0. Open it immediately with your
agent's built-in image-reading tool to inspect the pixels.

The CLI creates `.vishot/` under **your current working directory**. The capture
service does not choose the destination or write workspace files. The CLI
validates the returned PNG and dimensions, writes a unique mode-0600 temporary file,
and atomically publishes it without replacing an existing filename. Paths
with spaces and concurrent captures are supported. A `.vishot` symlink is
rejected to keep files in the intended workspace. Existing files survive
successes and failures. Captures stay until you explicitly remove the intended
files; no automatic cleanup runs.

Captures contain no overlapping apps, added shadow, cursor, annotations, or
Watermark. They do not change the clipboard or enter Capture history. There
is no alternate-window, clipboard, or older-image fallback. A missing ID
fails, even when another window from the same app remains available.

Minimized windows are unsupported and never restored. An exact Accessibility
window-ID match with `AXMinimized` supplies a specific `minimized_unsupported`
error when available; other failures return `capture_unavailable` or
`target_unavailable`. Accessibility is optional and never prompted. An
offscreen flag alone is not evidence of minimization. Connected displays are
supported; capture across native Spaces is best effort and never switches
Spaces. ScreenCaptureKit can reject unavailable windows.

Capture is bounded to 64 million pixels, 32768 pixels per side, and 90 MiB of
PNG bytes. Unsupported dimensions return `capture_unavailable`; excessive or
invalid encoded output returns `encoding_failed`. The CLI never publishes
bytes from a failed, timed-out, disconnected, or terminated request. Once a
complete response arrives, local validation and file writing precede success.

## Explain an interface from the captured image

Capture once, inspect that image, then annotate **that exact input**. This keeps
your explanation tied to the pixels you saw even if the live window changes.

1. Run `vishot windows` and select the exact live window ID.
2. Run `vishot capture --window-id 42` with that ID.
3. Immediately read the returned `capture.path` with your agent's built-in
   image-reading tool. JSON and a file path alone are not visual inspection.
4. Choose marks from the inspected image, then run `annotate --input` with the
   same `capture.path`. Use inline JSON by default. Include `--open` when
   presenting the explanation; omit it for a save-only draft.
5. Read the returned `annotation.path` with the built-in image reader to check
   the marks. For revisions, apply the complete revised batch to the original
   input, rather than adding marks to an already flattened result.

For example, after reading a 1600 × 1200 capture at the illustrative path below:

```sh
vishot annotate --input "/workspace/.vishot/window-42-9ab68a91-631e-4497-b28b-c19a3f06692a.png" --annotations '{"schemaVersion":1,"annotations":[{"type":"rect","x":100,"y":200,"width":240,"height":80,"color":"yellow"},{"type":"arrow","from":{"x":420,"y":160},"to":{"x":340,"y":220}},{"type":"text","x":420,"y":100,"text":"Save your changes"}]}' --open
```

Replace the example path and geometry with the actual returned path and observed
image coordinates. The CLI accepts JSON, not natural-language instructions.
Creating a JSON file is optional: use exactly one of `--annotations <JSON>` or
`--annotations-file <path>`. For a saved batch, a draft command is:

```sh
vishot annotate --input "/workspace/input.png" --annotations-file "/workspace/explanation.json"
```

### Annotation batch schema

Any local PNG meeting the image limits is accepted; a Vishot capture is not
required. The complete version 1 batch has this shape:

```json
{
  "schemaVersion": 1,
  "annotations": [
    {"type": "rect", "x": 100, "y": 200, "width": 240, "height": 80, "color": "yellow"},
    {"type": "arrow", "from": {"x": 420, "y": 160}, "to": {"x": 340, "y": 220}},
    {"type": "text", "x": 420, "y": 100, "text": "Save your changes\nThen continue", "color": "purple"}
  ]
}
```

`schemaVersion` and `annotations` are required. The ordered array contains
1–256 objects, drawn in array order with later marks on top. Unknown fields at
the batch, annotation, or point level are rejected. Each type accepts only its
fields shown above; `color` is optional for every type. The six exact color
names are `red`, `yellow`, `green`, `purple`, `white`, and `black`; the default
is `purple`. Font, font size, and stroke options are theme-defined, not JSON
fields.

All geometry uses **input image pixels**, measured from its top-left, with x
rightward and y downward. Finite fractional numbers are accepted; booleans are
not numbers. Discovery bounds in global points are not annotation coordinates.

- Text requires `x`, `y`, and nonblank `text`. The anchor is the text box's
  top-left, not its baseline or center. Explicit `\n` line breaks are supported.
  The anchor must be inside the image, but overflowing text is clipped at the
  image edge, not rejected or automatically wrapped.
- Arrows require `from` and `to` point objects, each with `x` and `y`. Both
  endpoints must be inside the image and must differ. The arrowhead is at `to`.
- Rectangle outlines require `x`, `y`, positive `width`, and positive `height`.
  The origin must be inside; `x + width <= image width` and
  `y + height <= image height`. Rectangles use outline treatment; very thin
  geometry can have no visible interior once the border is drawn.

Inside means `0 <= x < image width` and `0 <= y < image height`. These checks
bound the supplied geometry; rendered strokes, arrowheads, shadows, or text
can extend beyond it and are clipped to the image canvas. Pixel treatment can
snap arrow/rectangle marks to its cell grid; text retains its supplied top-left
anchor.

JSON is limited to 1 MiB (1,048,576 UTF-8 bytes), whether inline or file-based.
Each text value is limited to 16 KiB (16,384 UTF-8 bytes), with 256 KiB
(262,144 bytes) combined across the batch. The input must be one complete PNG,
at most 90 MiB encoded, 32768 pixels per side, and 64 million pixels total.
Encoded output is also limited to 90 MiB.

### Theme and DPI

Each request takes a read-only settings snapshot from
`~/.config/vishot/config.toml` to resolve the selected Pixel or Smooth style.
An absent file uses the normal default style; an unreadable or invalid settings
file fails with `invalid_arguments`. The command does not watch or change
settings, start the interactive app, or reuse its in-memory session state.
The shared parser validates the whole configuration: a valid `style` does not
hide an invalid shortcut, history preference, or legacy theme value. Legacy
`theme = "clean"` selects Smooth; an explicit modern `style` takes precedence.

The helper registers the containing app's bundled fonts before resolving the
treatment. Missing or unregistrable bundled fonts fail with `rendering_failed`
(exit 9) before publication, rather than silently drawing fallback Pixel text.

The renderer retains the selected theme's point-based font, stroke, and
arrowhead sizing. PNG DPI supplies the points-to-pixels scale:

- Missing, invalid (nonfinite or nonpositive), or nonsquare metadata uses 1x.
  Square means the two axes differ by at most 0.02 DPI.
- Finite, positive, square DPI must be within 9–2304 inclusive. PNG endpoint
  quantization is allowed within 0.013 DPI: both axes must be in
  `[8.987, 2304.013]`, then horizontal DPI is clamped to `[9, 2304]` and divided
  by 72. Valid 72/144 DPI gives 1x/2x sizing.
- Otherwise, finite, positive, square DPI returns exit 2, `invalid_image`, and
  no output. Correct the source PNG's DPI metadata before retrying; it does not
  silently fall back to 1x.

This affects mark sizing, not public pixel coordinates. The input is never
resized.

### Annotation results and opening

The command saves a separate flattened PNG under the current workspace's
`.vishot/`, leaving the original file unchanged and keeping its pixel
dimensions. Marks are composited onto the original image, not onto a recapture.
Grayscale inputs render in RGB so marks retain their colors; 16-bit inputs
retain 16-bit components rather than being reduced to 8-bit precision.
The agent CLI adds no watermark and changes neither clipboard nor Capture
history. Editing an existing PNG needs no Screen Recording or Accessibility
permission. Both input and output remain until explicitly scoped cleanup.

Save-only is the default. Success exits 0 and returns:

```json
{"schemaVersion":1,"ok":true,"annotation":{"path":"/workspace/.vishot/annotation-9ab68a91-631e-4497-b28b-c19a3f06692a.png","width":1600,"height":1200,"style":"pixel","openingStatus":"not_requested"}}
```

`style` reports `pixel` or `smooth`. With `--open`, the saved file is handed to
macOS's default image application only after publication. `openingStatus` is
`accepted` if macOS accepts the request; this does not prove a viewer displayed
the image or that the user saw it. Opening may activate the viewer. This flag
is the supported presentation route; a separate shell `open` command is not
needed.

If the open request fails, exit 11 and `ok: false` still retain the complete
`annotation` result and saved path:

```json
{"schemaVersion":1,"ok":false,"annotation":{"path":"/workspace/.vishot/annotation-9ab68a91-631e-4497-b28b-c19a3f06692a.png","width":1600,"height":1200,"style":"smooth","openingStatus":"failed"},"error":{"code":"opening_failed","message":"The annotated PNG was saved, but macOS did not accept the open request."}}
```

Report the retained path and opening failure separately; do not recapture or
reapply the marks just to recover the file. Other failures publish no new
annotation result. Messages in examples are illustrative, not stable strings.

### Correct an invalid batch

Validation rejects the entire batch before rendering or publishing output.
Malformed JSON returns `invalid_json`; parseable invalid batches return
`invalid_annotations` with field-level details when available:

```json
{"schemaVersion":1,"ok":false,"error":{"code":"invalid_annotations","message":"Invalid annotation batch.","problems":[{"index":1,"field":"annotations[1].to.x","reason":"Expected a finite image-pixel number in [0, 1600)."}]}}
```

`error.problems[]` contains `field`, `reason`, and an optional zero-based
annotation `index`. Batch-level problems omit `index`; malformed JSON and
byte-limit failures need not include `problems`. Correct every reported field,
then retry the complete batch against the same original `--input`. Successful
marks from an otherwise invalid batch are not partially saved.

## Background startup and authorization

For `windows` and `capture`, the CLI connects to its containing app. If the
service is absent, it asks Launch Services to start that actual app without
activation, passing a
background-launch argument. The app suppresses automatic first-time setup for
that launch. Launch Services starts the containing app even if another
installation with the same bundle ID is running. Concurrent startup attempts
use an endpoint lock; duplicate background instances exit before initializing
the normal app UI or hotkeys. Requests do not open setup, permission prompts,
the picker, the editor, or Capture history. Complete authorization in Vishot before
using discovery. Accessibility permission is not required for this command.

The signed app checks Screen Recording authorization without prompting and
enumerates windows; the CLI does not request capture authorization itself.
No target app is activated and no window is raised, restored, or moved.

Both startup and request waits default to 5 seconds. You can set either to a
finite value from 0.05 through 60 seconds:

```sh
vishot windows --startup-timeout 10 --timeout 3
```

## Errors and exits

Failures write the same JSON envelope to stdout, omit `windows`, and exit
nonzero. Read the stable error code rather than matching message text:

```json
{"schemaVersion":1,"ok":false,"error":{"code":"permission_denied","message":"Allow Screen Recording for Vishot in System Settings > Privacy & Security, then reopen Vishot manually and retry. No permission prompt was opened."}}
```

| Exit | Code | Meaning |
| --- | --- | --- |
| 2 | `invalid_arguments` | Unknown command, invalid or conflicting options, invalid timeout, or unreadable/invalid annotation settings. |
| 2 | `invalid_json` | Annotation JSON cannot be parsed. |
| 2 | `invalid_annotations` | Annotation batch schema, fields, geometry, or byte limits are invalid. |
| 2 | `invalid_image` | Local input is unreadable or is not a complete PNG within image limits. |
| 3 | `permission_denied` | The app lacks Screen Recording authorization. |
| 4 | `startup_failed` | The containing app is missing, invalid, or cannot launch. |
| 5 | `timeout` | Launch Services, startup readiness, or a request exceeded its deadline. |
| 6 | `service_failure` | Enumeration, connection, protocol, or service failed. |
| 7 | `target_unavailable` | The exact window disappeared or is not eligible. |
| 8 | `capture_unavailable` | macOS cannot capture the window in its current state. |
| 8 | `minimized_unsupported` | The exact window is reliably known to be minimized. |
| 9 | `encoding_failed` | PNG encoding, validation, dimensions, or size failed. |
| 9 | `rendering_failed` | Local annotation rendering failed. |
| 10 | `output_write_failed` | The caller cannot publish a new workspace-local PNG. |
| 11 | `opening_failed` | Annotated PNG is saved and returned, but macOS rejected opening it. |

`--version` returns `{"schemaVersion":1,"ok":true,"version":"0.1.0"}`
using the containing app's actual version, without starting the service.

## Service boundary for implementers

`VishotAgent` owns the versioned Codable contract, `AgentClient`, `AgentServer`,
and `AgentDiscovery`. `AgentService` adapts live CoreGraphics data to candidate
snapshots and supplies a nonprompting authorization check. The CLI boundary
tests launch the compiled executable in an isolated app layout against a
controlled service, including a Launch Services substitute app.

The transport is private: a Unix socket in a mode-0700 user-owned directory,
keyed by the canonical containing app path. Both peers verify the user's UID.
Each connection carries one UUID-correlated request and one length-prefixed
response, capped at 128 MiB (PNG Data is base64 inside this private envelope).
The app accepts up to eight concurrent workers,
with a 32-connection listen backlog and 65-second wire deadlines. Excess load
fails explicitly as a service error. A process lock guards stale socket
replacement. Client waits are bounded even if platform enumeration stalls;
the server monitors caller disconnection and enforces the requested handler
budget, independently capped at 60 seconds. It cancels abandoned handler
tasks and releases their connection and worker slot without waiting for a
platform callback to cooperate. Late results are discarded by a completion
gate that has no socket ownership. An underlying non-cancellable platform
operation may still finish later; it cannot hold a service slot or publish a
file. Service work runs off the main thread and never enters the
hotkey-to-overlay path.

The bundled CLI path is `Contents/Helpers/vishot`; its SwiftPM executable target
is `VishotCLI` to avoid a case-insensitive collision with `Vishot`. Packaging
signs the helper first, then the app, using the existing signing identity.
`AgentRequest(command: "capture", windowID: id)` requests isolated content.
The async service handler returns `.captured(AgentCapturedImage)` with target
identity, PNG bytes, and pixel dimensions. The client rejects a response for
another window ID. `AgentCaptureOutput.save` validates and publishes the PNG
in the caller process, returning the public `AgentCaptureFile`. Service bytes
are never included in public JSON. `AgentWindowCapture` uses a desktop-independent
ScreenCaptureKit window filter and raw PNG encoding, independently of editor
completion, watermark, clipboard, and history logic. Timed-out clients cannot
receive a late response on another caller's connection or publish a late file.

`VishotCLI` is a small process adapter for arguments, executable discovery,
stdout, and the main run loop. `VishotCLIExecution` owns command parsing,
dispatch, annotation orchestration, structured results, and exit statuses.
Annotation runs entirely inside the helper process using `VishotRendering`
for geometry, treatment resolution, fonts, drawing, and image encoding, and
`VishotConfiguration` for immutable full-configuration interpretation. Neither
shared module imports an executable target or live Settings lifecycle.

Local annotation reads the input and settings, renders, publishes the workspace
file, and optionally requests opening. It does not execute the GUI binary,
launch the app through Launch Services, connect to the capture service, or
request capture authorization. Capture startup/request timeout flags do not
apply to `annotate`. The signed app remains the owner of live capture and
authorization; the app and CLI consume the same rendering implementation.
