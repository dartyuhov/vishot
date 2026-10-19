# Visual theme verification

The integrated Pixel and Clean implementation passes the automated checks
below. Signed interactive verification is still pending. This record separates
source and test evidence from checks that require a person and display access.

## Environment and automated results

Checks ran on October 19, 2026, on arm64 macOS 26.7.1 (25G241), from the final
theme worktree based on integration commit `490a443`.

- `swift build`: passed.
- `swift test --force-resolved-versions`: 188 XCTest tests passed, zero failures.
- `./scripts/build.sh`: release bundle built with the default Apple Development
  identity; the script's `codesign --verify --deep --strict` passed.
- Bundle location: `build/Vishot.app` in the final theme worktree. This build
  was not installed or launched; the existing installed app was not replaced.

The new history regression first failed on the integrated implementation:
Clean combining marks extending above the typographic line box were cropped
from the preview but still indexed as fully visible text. Bounds now include
actual glyph ink and the halo. The regression verifies both clipped and fully
visible search results against rendered pixels.

Existing tests cover Pixel cell edges and shadows, Clean vector edges, multiline
text and caret placement, crop fidelity, and output at 1x and 2x. Settings tests
cover persistence, conservative TOML edits, invalid values, reloads, and session
deferral. History tests cover legacy metadata, unsupported styles, re-editing,
undo/redo, revision identity, search, loading/error/empty feedback, and stored
preview preservation. Completion tests exercise delayed PNG/TIFF data, real
file saves, save failures, Save As cancellation, and replaced sessions.

These tests use controlled images and AppKit objects. They don't establish
physical-display legibility, live capture permissions, or signed GUI behavior.
Raw test binaries can use fallback fonts rather than bundled Pixel fonts.

## Integration audit

The source audit covered the complete picker/history/editor/output lifetime.

- Reusable picker panels and history UI are prepared at startup, display
  changes, or idle preference changes. Theme preparation stays off the hotkey
  path. Hint layers retain their existing grow-and-reuse behavior.
- Target labels, hints (including typed prefixes), HUDs, region crosshairs,
  crop feedback, caret, toolbar swatches, disabled controls, and Settings error
  feedback consume resolved styles. Crop drawing treatment is centralized;
  Clean crop handles now use rounded geometry and a thin border.
- Obsolete implicit-Pixel HUD, selection, measurement, drawing, and watermark
  adapters and their appearance caches are removed. Immutable Pixel glyph/cell
  geometry remains part of its drawing treatment.
- Export takes the document's annotation style. History-to-editor transitions
  retain the session UI theme while restored markup retains its own style.
- `OutputStyle` remains an explicit immutable snapshot across lazy paste,
  background save, fallback copy, and Save As cancellation. Stored history
  previews remain watermark-free and aren't regenerated on a theme change.
- Annotation-free export still returns original pixels (or their direct crop).
  Original image-space geometry, cursor behavior, and input controls are
  independent of theme selection.

## Pending signed interactive checks

No desktop screenshot, keyboard/mouse control, or interactive browser tools are
exposed in this agent session. Connected MCP resource lists are empty. There
was no interactive access to select or verify a physical 1x or 2x display, so
neither scale's signed GUI checks were performed. No screenshot/control shell
fallback was used. Code signing success isn't a substitute for these checks.

With interactive access, run every row for both Pixel and Clean on actual 1x
and 2x displays, using an intentionally installed signed bundle. Record display
models/scales, bundle revision, permissions, and observed results here.

| Flow | Required observations | Result |
| --- | --- | --- |
| Idle settings and relaunch | Theme applies immediately; choice survives restart; Pixel uses bundled fonts; Clean is legible | Not performed |
| Active configuration changes | Pending feedback; picker/history/editor and Save As cancel retain one session theme; next session adopts changes | Not performed |
| Window, hint, element, screen | Labels, outlines, typed hints, HUDs, loading and permission/error feedback; unchanged keyboard/mouse controls | Not performed |
| Region | Crosshair, dim, size label, display switching, keyboard corners, mouse drag, copy, and edit | Not performed |
| Editor | Arrows, rectangles, multiline text, caret, colors, crop/resize handles, undo/redo, all HUD layouts, and discard | Not performed |
| Output | Paste PNG/TIFF into another app; save, save+copy, Save As accept/cancel; small-image omission and watermark toggle | Not performed |
| Delayed output | Change theme after copying/before pasting and during save; original output style remains | Not performed |
| History | Loading, empty, selected, search/no-match, and error states; re-edit both styles under opposite UI theme; yank legacy entries | Not performed |
| Multiple displays | Cross-display picker/editor placement and actual 1x/2x sharpness, contrast, and legibility | Not performed |

The remaining acceptance blocker is signed interactive verification on those
displays. No live GUI flow or physical-scale result is claimed by this record.
