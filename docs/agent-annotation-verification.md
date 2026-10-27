# Signed agent annotation verification

Earlier live verification on October 27, 2026 passes capture, immediate built-in image
reading, mixed-mark annotation of that exact PNG, and built-in reading of the
flattened result. Pixel and Smooth render correctly on representative 1x and
2x PNGs. macOS accepts `--open` and starts Preview, but no Preview document
window is observed. Actual viewer display remains unverified. After renderer
review fixes, a new isolated signed build passes eight save-only PNG smoke
checks, including grayscale and 16-bit RGB inputs. The capture/open observations
below belong to the earlier build; they are not rerun on the final renderer.

## Runtime and scope

This evidence covers ticket `vishot-d88` in the annotation integration worktree,
including its uncommitted implementation. It supplements the historical
[capture verification](agent-cli-verification.md) and the
[agent CLI contract](agent-cli.md).

- Host: macOS 26.7.1, build `25G241`, native arm64.
- Bundle: `build/Vishot.app` in `vishot-agent-annotations`.
- Build command: `./scripts/build.sh`, without the install argument.
- Signing: existing stable Apple Development identity, hardened runtime.
  `codesign --verify --deep --strict build/Vishot.app` exits 0 after building
  and again after runtime checks. Signing-account details are omitted here.
- Bundled CLI version: `0.1.0`, returned in schema version 1 JSON.
- Agent: OpenCode, model `github-copilot/gpt-6.1-sol`; PNG inspection uses the
  image-capable `functions.read` tool, not JSON-derived visual assumptions.
- Settings: each CLI subprocess receives `CFFIXED_USER_HOME` pointing at a
  test-owned Pixel or Smooth home. Each isolated config has `watermark = true`.
  The user's configuration and permissions are not changed.

The user's installed app remains PID `83288` throughout the snapshots. The
test-owned capture service is PID `91751`; the public fixture is PID `91718`.
Only those two test-owned processes receive `SIGTERM` after capture checks.
The installed app is never replaced, terminated, or relaunched. No application
source changes, staging, commits, merges, pushes, PRs, or tracker closure occur
as part of this verification.

## Retained evidence

All temporary source, compiled probes, isolated settings, raw observations,
and PNGs remain under this local directory outside the repository:

```text
/var/folders/nr/0qk2bwcd7vxbk9wj6rc735wr0000gp/T/opencode/vishot-d88-live-20261027
```

The `/private/var/` spelling resolves to the same directory. The directory is
local evidence, not a permanent published artifact. Raw discovery JSON includes
other apps' metadata; no personal window titles are reproduced in this public
document, and no personal window is captured.

- `probe.swift`, `probe`, and `Fixture.app`: controlled AppKit fixture,
  clipboard-count/history-manifest snapshots, image properties, and viewer
  observations. The fixture contains only public verification text.
- `run.py`: actual bundled-CLI subprocess commands, JSON/stderr retention,
  process samples, original-file SHA-256 assertions, and before/after checks.
- `home-pixel/` and `home-smooth/`: isolated annotation settings.
- `*-report.json`, `*-before.json`, `*-after.json`: request results and desktop
  snapshots. History manifests contain paths and SHA-256 hashes, not image
  contents. Clipboard probing reads only `changeCount`.
- `*-processes.json`: finite process samples, nominally 15 ms apart plus probe
  execution time. These samples are not a system-call trace.
- `viewer-observation.json`, `viewer-all-windows.json`, `viewer-ax.json`:
  Launch Services default-app resolution and running-app/CG/AX observations.
- `images.json`, `signature-summary.json`, and `capture-marks.json`: image
  dimensions/DPI/hashes, redacted signing summary, and the exact capture batch.

## Earlier exact-capture explanation

The regular AppKit fixture creates a 640 × 432 point titled window, orders it
behind existing windows without activation, and reports its own window ID.
The actual bundled CLI discovers that ID and captures only that fixture.

```sh
build/Vishot.app/Contents/Helpers/vishot windows
build/Vishot.app/Contents/Helpers/vishot capture --window-id 2846
```

The live ID is specific to this run. Both requests exit 0 with empty stderr.
Capture returns 1280 × 864 pixels at 144 DPI. The built-in Read then shows the
heading **PUBLIC FIXTURE / EXACT PIXELS**, cyan **7 x 6 = 42**, yellow
**[ SAVE ]**, and white **No private content** on a blue background. No
overlapping app, cursor, or Vishot watermark appears.

After that Read, the agent chooses this complete batch against the exact
returned PNG, without another capture:

```json
{
  "schemaVersion": 1,
  "annotations": [
    {"type":"rect","x":105,"y":550,"width":320,"height":90,"color":"yellow"},
    {"type":"arrow","from":{"x":740,"y":470},"to":{"x":435,"y":585},"color":"red"},
    {"type":"text","x":650,"y":310,"text":"Save the answer\n42 is correct","color":"purple"}
  ]
}
```

The command uses `annotate --input <capture.path> --annotations <inline JSON>
--open`. It exits 0 with `style: "pixel"`, unchanged 1280 × 864 dimensions, and
`openingStatus: "accepted"`. A second built-in Read visibly confirms the
yellow outline around **[ SAVE ]**, the red arrow pointing toward its right
edge, and two readable Pixel-font text lines. The original fixture pixels
remain visible around the marks; there is no watermark. The input SHA-256
assertion passes before and after annotation.

The exact paths under the evidence directory are:

| Artifact | Relative PNG path |
| --- | --- |
| Original capture | `.vishot/window-2846-9e1b9902-d096-4566-9ae3-2245996a31fe.png` |
| Presented Pixel result | `.vishot/annotation-3ede9553-2d30-4b80-90dc-3f26a467ac0e.png` |

The capture input's retained SHA-256 is
`9048f19a867f6e8eb50350ef92b563f8cda23208d2c6ce99506195f07134eb03`.

## Earlier Pixel, Smooth, and DPI checks

The probe also generates local PNGs directly with CoreGraphics/ImageIO, without
screen capture. The 1x input is 640 × 400 at 72 DPI; the 2x input is 1280 × 800
at 144 DPI. Both contain a blue rectangle on a pale background.

Each style receives a yellow rectangle outline, red arrow, and two-line purple
text batch using inline JSON. The 2x batch doubles all supplied coordinates.
All four commands exit 0, return the requested style and `not_requested`, and
preserve the input dimensions and DPI. Original-file SHA-256 assertions pass.
All four output images are actually read with the built-in image tool.

| Style and input | Relative output PNG path | Visual observation |
| --- | --- | --- |
| Pixel, 1x | `.vishot/annotation-d1c56204-1c82-4015-b2d5-4ea68f5e052b.png` | Pixel text, stepped arrow, hard outline shadow |
| Pixel, 2x | `.vishot/annotation-af504d51-b0c3-46b5-9f71-ed7811e7ac61.png` | Same composition at twice the pixel sizing |
| Smooth, 1x | `.vishot/annotation-928a94d1-8296-4be2-a303-5990acb99a03.png` | Smooth mixed-case text, continuous arrow and outline |
| Smooth, 2x | `.vishot/annotation-4d7f6f80-45a7-45a1-8788-6d0271025c23.png` | Same composition with doubled font/stroke sizing |

No output shows a watermark. The rectangle stays unfilled, the arrowhead is at
the supplied `to` end, and the two text lines occupy the supplied top-left
area. These are representative visual checks, not exhaustive DPI or color
coverage. The retained input hashes are:

- `any-1x.png`:
  `087d09b9d601c3d9f438743eeda7019320b5ec4dc5df37fe78f2b215a818a381`.
- `any-2x.png`:
  `2a5aaddd56f13ea091f432ad532f13e65476e9276b39d7101ee7edb85c27e296`.

## Existing-PNG isolation and validation

After stopping only the owned fixture and built capture service, a further
Smooth request uses `--annotations-file` against `any-1x.png`. It exits 0,
returns `not_requested`, and saves
`.vishot/annotation-abcef200-9778-4b08-b5e4-a303fc98e4d5.png`. Before/after
running-app observations show only the unchanged installed Vishot process;
the test service is absent and does not restart. The input SHA-256 matches
before and after.

Source inspection supports that observation: the helper replaces itself with
the containing app's headless annotation entry point, and `main.swift` handles
that mode before creating `NSApplication` or `AppDelegate`. The local command
reads the PNG and isolated settings, renders, publishes, and optionally calls
the workspace opener; it does not connect to the capture service or run its
authorization check. This establishes the architectural lack of a new capture
permission requirement, with isolated process observations. It is not a
fresh-denied TCC test: the installed app remains running and this account
already has capture authorization.

A separate three-mark batch sets the arrow's `to.x` to 640 on the 640-pixel
input. The CLI exits 2 with `invalid_annotations` and this indexed detail:

```json
{"index":1,"field":"annotations[1].to.x","reason":"Expected a finite image-pixel number in [0, 640)."}
```

The complete `.vishot/` path set is unchanged across that rejection: even the
valid rectangle and text are not partially published. The original hash,
clipboard count, and history manifest remain unchanged.

## Clipboard, history, and desktop observations

Every annotation request and both live capture-service requests have matching
before/after clipboard count `85` and identical manifests for all 125 history
files. The manifests include metadata, original PNGs, previews, thumbnails,
and retention state. No clipboard payload is read or replaced. Snapshot checks
cover the user's real history location, including requests using isolated
annotation homes.

The four save-only style/DPI requests and later headless validation requests
also have matching foreground PIDs and ordered on-screen window-ID arrays.
Discovery preserves both. Capture has a foreground PID change from `44875` to
`67358` and a changed window array; neither is the fixture or built service
PID. The observations cannot attribute that change, so this run does not claim
desktop invariance for capture. No desktop-control or browser tools run.

## Earlier default image app opening

The only opened document is the completed public fixture result, through the
actual CLI `--open` path. macOS reports acceptance, resolves the PNG's default
app to `/System/Applications/Preview.app`, and starts Preview PID `91956`.
Preview is absent from the initial process samples and present afterward.

The later observation finds Preview running but inactive. CG queries over both
on-screen and all windows find no matching annotation document window. A
read-only AX query succeeds with zero Preview windows. These checks do not
activate Preview, switch Spaces, or inspect other documents. Therefore this
run confirms OS acceptance and viewer-process startup, not document display or
that a person saw the image. The built-in Read independently verifies the
saved flattened pixels. The output remains retained despite the viewer gap.

## Final-renderer signed rebuild

After the grayscale, 16-bit precision, small-outline, and DPI review fixes land,
`./scripts/build.sh` rebuilds the isolated release bundle with the same stable
Apple Development signing family and no install argument. Deep strict
signature verification passes before and after the new runtime checks. The
bundled CLI still reports version `0.1.0`. This is isolated signed-build runtime
evidence, not installed signed-bundle runtime verification.

The retained `final-renderer.py` runs eight save-only requests using the actual
rebuilt helper, the existing isolated Pixel/Smooth homes, and inline JSON.
It reuses the nonprivate `any-1x.png` and `any-2x.png` inputs and generates
640 × 400 grayscale 8-bit and RGB 16-bit PNG fixtures using standard PNG chunks.
Each batch has the earlier rectangle, arrow, and multiline text plus a small
21 × 21 pixel green outline (42 × 42 at 2x).

All eight requests exit 0 with empty stderr, the selected style, and
`openingStatus: "not_requested"`. Input SHA-256 hashes and pixel dimensions
remain unchanged. Both 16-bit RGB inputs produce 16-bit RGBA PNGs, as checked
from their PNG headers. That smoke check verifies retained output bit depth;
exact sample-precision preservation is covered by the parent's regression
suite, not inferred from the header or visual inspection.

The final output paths under the retained evidence directory are:

| Style and input | Relative output PNG path |
| --- | --- |
| Pixel, 1x | `.vishot/annotation-9d1908d7-3421-4bed-b5ae-1238bc3de5d8.png` |
| Pixel, 2x | `.vishot/annotation-1dd1771c-f42a-4f9e-b9e7-cead62119730.png` |
| Pixel, grayscale 8-bit | `.vishot/annotation-4592ff9f-8aec-40e6-978f-625c374ab43b.png` |
| Pixel, RGB 16-bit | `.vishot/annotation-f2d17fc3-ec3e-47e7-98bc-93955cc2002e.png` |
| Smooth, 1x | `.vishot/annotation-42f1453b-5204-4f0f-a4d4-808a33cddb62.png` |
| Smooth, 2x | `.vishot/annotation-629f808b-4d04-4f88-a418-aae3be7ebb29.png` |
| Smooth, grayscale 8-bit | `.vishot/annotation-785d3b2e-a199-4809-a752-514088eb7bd2.png` |
| Smooth, RGB 16-bit | `.vishot/annotation-ea8da595-223e-43be-9254-bcb9f5ed892e.png` |

Built-in image Read inspects the final Pixel grayscale, Smooth 16-bit, and both
2x outputs. It visibly confirms colored mixed marks, readable multiline text,
distinct Pixel/Smooth treatment, unfilled small green outlines, and no
watermark. Grayscale source bands and the 16-bit fixture's generated gradient
remain visible around the marks.

One additional rebuilt-release request uses square 2305 DPI. It exits 2 with
`invalid_image` and an explicit `9...2304` DPI message; the complete output
path set stays unchanged. Source inspection confirms supported square DPI is
9–2304 inclusive, with PNG quantization tolerance, and unsupported positive
finite square DPI fails explicitly. Missing, invalid, or nonsquare metadata
uses 1x. Endpoint coverage belongs to the parent's regression suite; this
runtime slice checks ordinary 72/144 DPI and the 2305 DPI rejection.

All nine final requests preserve clipboard count `93`, the identical 125-file
history manifest, foreground PID, and ordered on-screen window-ID arrays.
Before/after app snapshots contain only the unchanged installed Vishot process;
the isolated capture service does not start. Raw `final-*-report.json` files
record per-request hashes and observations, and `final-renderer-summary.json`
maps successful requests to PNG paths and output bit depths. The earlier raw
evidence remains retained separately under its original filenames.

## Checks and remaining gaps

The signed release build, repeated deep strict signature check, compiled CLI
version, four theme/DPI runs, exact-capture explanation, headless file-based
batch, and indexed whole-batch rejection pass. All request stderr files are
empty. The final-renderer rebuild and eight PNG successes plus explicit DPI
rejection also pass. The parent session verifies 284 full Swift tests after
the renderer fixes; this verification does not repeat that suite. Packaging
checks are not repeated for this runtime-only slice.

The following checks remain open:

- Actual default-viewer document display; `accepted` plus a process is not
  window or visual-display evidence.
- A relocated installed signed bundle. This run uses the signed development
  bundle and its actual bundled CLI without replacing the user's installation.
- Fresh-denied Screen Recording or Accessibility context; no TCC reset or new
  permission prompt is exercised.
- Native Intel, macOS 14 runtime, native cross-Space capture, and interactive
  picker/editor responsiveness during concurrent capture. Historical gaps in
  the capture verification remain applicable.
- Real OS rejection of `--open`; this run exercises acceptance only. Injected
  failure tests belong to the parent test evidence.
- Capture and real `--open` on the final-renderer rebuild. Their earlier
  observations remain useful historical evidence, not final-build reruns.

The test-owned fixture and background capture service are stopped. Preview and
the user's installed app remain untouched after observation, and all raw
evidence and PNGs stay available for review.
