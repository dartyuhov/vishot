---
name: vishot-capture
description: Capture and inspect macOS windows with Vishot, then explain an interface with text, arrows, and rectangle outlines on the exact inspected PNG. Use for desktop visual inspection, covered-window capture, annotated explanations, or marking an existing local PNG.
compatibility: macOS 14 or newer, installed Vishot app, terminal execution, and a built-in image-reading tool. Live discovery/capture also requires Vishot Screen Recording permission.
---

# Inspect and explain a window with Vishot

Capture an exact live window into the current workspace, then read its PNG as
visual input. To explain it, annotate that same input and use `--open` to
present the result. The native CLI needs no Node, Python, Swift, MCP server,
or plugin. Use the current harness's approved terminal and built-in image tools.

## Discover, capture, read

Complete these steps for each requested inspection:

1. Run commands from the user's intended workspace so output belongs to that
   task. Use `vishot` from PATH. If unavailable, check `~/.local/bin/vishot`, or
   ask the user for the installed app location and use its
   `Contents/Helpers/vishot` executable. Quote paths containing spaces. Settings
   offers optional user-local CLI installation; don't install another runtime.
2. Run `vishot windows`. Require exit 0 and JSON `schemaVersion: 1, ok: true`.
   Select the exact `windows[].id` using `app.name`, `app.bundleID`, `app.pid`,
   `title`, and `bounds`. If multiple windows fit, ask which one. IDs describe
   live windows, not durable identities; rerun discovery after a stale-ID error.
3. Run `vishot capture --window-id <id>`, replacing `<id>` with the selected
   numeric ID. Require exit 0, `ok: true`, and a `capture` result containing
   `path`, `target`, `width`, and `height`. Confirm `capture.target.id` matches
   the request. Keep the exact returned absolute path for this task.
4. **Immediately open `capture.path` with your built-in image-reading tool.**
   For example, use OpenCode's image-capable Read tool, Claude Code's Read
   tool, or Codex's `view_image`, as available in the current harness. A path,
   dimensions, JSON, or base64 text is not visual inspection. If image input
   is unavailable or denied, report that you captured a file but could not
   inspect it; don't claim to have seen its content. Don't launch an external
   viewer as a substitute.
5. Answer from the image you actually opened. For an annotated explanation,
   continue below using that exact `capture.path`, even if the window changes.
   A new inspection after relevant app changes starts a new capture/read cycle;
   retain previous files unless cleanup is requested.

For example, if discovery identifies window 42:

```sh
vishot windows
vishot capture --window-id 42
```

A successful capture has this shape (values are illustrative):

```json
{"schemaVersion":1,"ok":true,"capture":{"path":"/workspace/.vishot/window-42-9ab68a91-631e-4497-b28b-c19a3f06692a.png","target":{"id":42,"app":{"pid":123,"bundleID":"com.example.Editor","name":"Editor"},"title":"Document","bounds":{"x":-800,"y":30,"width":800,"height":600}},"width":1600,"height":1200}}
```

`target.bounds` and discovery bounds use **points** in CoreGraphics global
coordinates: primary display top-left origin, y downward, possibly negative
x/y on other displays. Capture `width` and `height` are **image pixels**.
The file is complete and immediately readable before success is reported.
Concurrent commands create unique files under the caller's `.vishot/`.

## Annotate the inspected input

For an explanation, complete this sequence after the built-in image read. For
an existing local PNG, first read that file, then use it as the original input;
no capture permission is needed for annotation.

1. Keep the original inspected path as `--input`. Choose coordinates from its
   actual pixels and dimensions, not from discovery's global point bounds.
2. Build one versioned JSON batch mixing the needed text, arrows, and rectangle
   outlines. Use inline `--annotations` by default; the CLI does not interpret
   natural-language annotation requests.
3. Run `vishot annotate --input <original-path> --annotations <JSON> --open`
   when presenting an explanation. Omit `--open` for a save-only draft. The
   flag handles default-image-app presentation without a separate shell viewer
   command. Opening can activate the viewer; plain capture preserves focus.
4. Require exit 0 and `ok: true`, then immediately read `annotation.path` with
   the built-in image reader to inspect the marks. Report what you actually
   observed. `openingStatus: accepted` proves only macOS accepted the request,
   not that the image was displayed or seen.
5. Revise by applying the complete corrected batch to the original input.
   Preserve the exact inspected pixels: do not recapture between inspection
   and annotation or stack revisions onto already flattened marks.

For a previously inspected 1600 × 1200 image, an illustrative mixed batch is:

```sh
vishot annotate --input "/workspace/.vishot/window-42-9ab68a91-631e-4497-b28b-c19a3f06692a.png" --annotations '{"schemaVersion":1,"annotations":[{"type":"rect","x":100,"y":200,"width":240,"height":80,"color":"yellow"},{"type":"arrow","from":{"x":420,"y":160},"to":{"x":340,"y":220}},{"type":"text","x":420,"y":100,"text":"Save your changes"}]}' --open
```

Replace the example path and coordinates with the original returned path and
the observed image geometry. Creating a JSON file is optional. For a batch
already saved as JSON, use exactly one source; this example saves a draft:

```sh
vishot annotate --input "/workspace/input.png" --annotations-file "/workspace/explanation.json"
```

### Batch and geometry rules

The batch is `{"schemaVersion":1,"annotations":[...]}` with 1–256 objects.
Later objects draw over earlier ones. Unknown fields are rejected, including
inside point objects. Each type accepts the following required fields plus
optional `color`:

- `text`: `x`, `y`, `text`. The anchor is the text box's **top-left**, not its
  baseline or center. Text must be nonblank; explicit `\n` line breaks work.
  Overflow is clipped at the canvas edge, with no automatic wrapping.
- `arrow`: `from: {"x":...,"y":...}`, `to: {"x":...,"y":...}`. Both endpoints
  must be inside and different. The arrowhead is at `to`.
- `rect`: `x`, `y`, `width`, `height`. Width and height must be positive;
  `x + width <= image width` and `y + height <= image height`. Outline treatment
  can leave no visible interior for very thin geometry.

All coordinates are finite **input image pixels**, top-left origin, x right,
y down; fractions are accepted, booleans are not numbers. Text anchors, arrow
endpoints, and rectangle origins require `0 <= x < image width` and
`0 <= y < image height`. Supplied geometry must satisfy these bounds; rendered
text, strokes, arrowheads, and shadows may extend past them and are clipped to
the canvas. Pixel-style arrow/rectangle marks can snap to its cell grid; CLI
text keeps its top-left anchor.

Colors are exactly `red`, `yellow`, `green`, `purple`, `white`, and `black`;
omitting `color` means `purple`. Theme-defined sizing is retained: font, font
size, and stroke overrides are not schema fields. Each request reads the
selected Pixel or Smooth style from `~/.config/vishot/config.toml` once; a
missing file uses the default, while invalid/unreadable settings fail. This
read-only snapshot does not reuse a running editor session or change settings.

Missing, invalid (nonfinite/nonpositive), or nonsquare PNG DPI uses 1x. For
finite, positive axes differing by at most 0.02 DPI, the supported range is
9–2304 inclusive, with 0.013 DPI endpoint quantization tolerance: both axes
must be in `[8.987, 2304.013]`. Clamp horizontal DPI to `[9, 2304]`, then divide
by 72 for mark sizing (72/144 DPI gives 1x/2x). Square DPI outside that tolerance
fails with exit 2, `invalid_image`, and no output; correct the source metadata
before retrying instead of assuming 1x. Coordinates remain pixels; no resizing
occurs.

JSON has a 1 MiB UTF-8 limit, each text has a 16 KiB UTF-8 limit, and combined
text has a 256 KiB UTF-8 limit. Input must be one complete PNG within 90 MiB,
32768 pixels per side, and 64 million pixels total; output is at most 90 MiB.

### Results and correction

Success returns a separate flattened PNG, leaving the original file unchanged:

```json
{"schemaVersion":1,"ok":true,"annotation":{"path":"/workspace/.vishot/annotation-9ab68a91-631e-4497-b28b-c19a3f06692a.png","width":1600,"height":1200,"style":"pixel","openingStatus":"accepted"}}
```

`width` and `height` match the input's pixel dimensions. `style` is `pixel` or
`smooth`; `openingStatus` is `not_requested` for save-only, `accepted` for an
accepted `--open` request, or `failed` when macOS rejects opening. An opening
failure exits **11**, returns `ok: false` and `error.code: opening_failed`, and
**retains `annotation` and its saved path**. Read the saved file, report the
path and opening failure, and let the user check their default PNG app; avoid
recapturing, rendering again, or introducing an unapproved viewer command.

Grayscale input renders in RGB for colored marks. A 16-bit input retains
16-bit components rather than being reduced to 8-bit precision.

Other failures produce no new usable annotation. Invalid batches are rejected
in full; use exit 2's `invalid_json`, `invalid_annotations`, or `invalid_image`
to distinguish malformed JSON, invalid batch content, and invalid input PNG.
For parseable batch errors, use the indexed field details when available:

```json
{"schemaVersion":1,"ok":false,"error":{"code":"invalid_annotations","message":"Invalid annotation batch.","problems":[{"index":1,"field":"annotations[1].to.x","reason":"Expected a finite image-pixel number in [0, 1600)."}]}}
```

Each problem has `field`, `reason`, and an optional zero-based annotation
`index`; batch-level problems omit `index`. Malformed JSON and byte-limit
errors need not supply `problems`. Correct all reported fields and retry the
whole batch against the same original input. `rendering_failed` exits 9;
`encoding_failed` exits 9 and `output_write_failed` exits 10.

Annotation replaces the helper process with the containing app binary's
headless renderer, which writes the output in that same process. It does not
use the live capture service, start the interactive app, or request capture
authorization. Both capture and annotation omit watermark, clipboard changes,
and Capture history. Keep originals and results until scoped cleanup.

## Supported states and desktop preservation

Vishot captures the window's own content, including fully covered windows and
windows on connected displays. It excludes overlapping apps, added shadow,
cursor, Watermark, and annotations. The signed app starts in the background
when needed; requests preserve focus, stacking, clipboard, and Capture history
and don't open the picker, editor, setup, or permission UI.

Minimized windows are unsupported and remain minimized. Native cross-Space
capture is best effort; never switch Spaces or raise, activate, move, or restore
a window to make an automated capture succeed. Ask the user to change its state
manually if needed. Offscreen coordinates alone don't establish native Space
support or prove minimization. Screen Recording authorization belongs to the
signed app; complete missing setup manually in Vishot. Accessibility is optional.

## Handle errors

Failures exit nonzero and return
`{"schemaVersion":1,"ok":false,"error":{"code":"target_unavailable","message":"..."}}`.
Read `error.code` and explain the actionable message. A capture failure has no
usable capture: don't substitute another window, an older file, or clipboard
content.

| Exit | Code | Response |
| --- | --- | --- |
| 2 | `invalid_arguments` | Correct the command or ID; capture accepts windows only. |
| 3 | `permission_denied` | Ask the user to enable Vishot Screen Recording in System Settings and reopen Vishot manually. |
| 4 | `startup_failed` | Ask the user to check the installed app location and open Vishot manually. |
| 5 | `timeout` | Report the timeout; retry once if appropriate, without using any older output. |
| 6 | `service_failure` | Report the service failure; ask the user to reopen/update Vishot if it persists. |
| 7 | `target_unavailable` | Rediscover live windows; reselect by identity and ask if ambiguous. |
| 8 | `capture_unavailable` | Explain the window is unavailable; do not infer that it is minimized. |
| 8 | `minimized_unsupported` | Ask the user to restore the window manually if they want another capture. |
| 9 | `encoding_failed` | Report that no valid PNG was saved. |
| 10 | `output_write_failed` | Check the caller workspace permissions, free space, and `.vishot/` directory; no clipboard fallback exists. |

`windows` and `capture` support `--startup-timeout <seconds>` and
`--timeout <seconds>` (5 seconds each by default, finite values from 0.05 through
60). These flags do not apply to `annotate`. A larger wait
is an explicit retry choice, not a reason to loop indefinitely. Captures are
bounded to 64 million pixels, 32768 per side, and 90 MiB of PNG bytes.

## Retention and explicit cleanup

Keep captures and annotated PNGs by default, including after the task finishes.
Track the returned absolute paths you created. Only when the user explicitly
requests cleanup,
remove the intended files from that list with your file tool or an exact-path
command, quoting each path. Confirm the scope if the request is ambiguous.
Avoid wildcard deletion or recursive removal of `.vishot/`: another task or
concurrent caller may own other captures there. Report which files you removed.
