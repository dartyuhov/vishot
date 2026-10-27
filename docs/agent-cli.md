# Agent CLI

The compiled CLI bundled with Vishot lists and captures live app windows without
moving or activating them. Run the executable in your installed app (adjust the app path
to match your installation):

```sh
~/Applications/Vishot.app/Contents/Helpers/vishot windows
~/Applications/Vishot.app/Contents/Helpers/vishot capture --window-id 42
~/Applications/Vishot.app/Contents/Helpers/vishot --version
```

The CLI runs on macOS 14 or newer without a development runtime. It ships in
the app's native architecture and reads the app's release version. A symlink
to the bundled executable also works. The app location comes from the
resolved executable path, so multiple installations have separate endpoints.

For agents, the repository includes a [capture skill](../skills/vishot-capture/SKILL.md)
covering exact-ID selection and immediate image reading. The optional external
installation command and Setup/Settings integration are documented in
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

The CLI creates `.vishot/` under **your current working directory**. The app
does not choose the destination or write workspace files. The CLI validates
the returned PNG and dimensions, writes a unique mode-0600 temporary file,
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

## Background startup and authorization

The CLI connects to its containing app. If the service is absent, it asks
Launch Services to start that actual app without activation, passing a
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
| 2 | `invalid_arguments` | Unknown command, extra argument, or invalid timeout. |
| 3 | `permission_denied` | The app lacks Screen Recording authorization. |
| 4 | `startup_failed` | The containing app is missing, invalid, or cannot launch. |
| 5 | `timeout` | Launch Services, startup readiness, or a request exceeded its deadline. |
| 6 | `service_failure` | Enumeration, connection, protocol, or service failed. |
| 7 | `target_unavailable` | The exact window disappeared or is not eligible. |
| 8 | `capture_unavailable` | macOS cannot capture the window in its current state. |
| 8 | `minimized_unsupported` | The exact window is reliably known to be minimized. |
| 9 | `encoding_failed` | PNG encoding, validation, dimensions, or size failed. |
| 10 | `output_write_failed` | The caller cannot publish a new workspace-local PNG. |

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
