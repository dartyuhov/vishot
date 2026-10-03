# In-place screenshot editor

Date: 2026-10-03
Status: approved design, not yet planned

## Goal

From the picker, ⇧↵ opens a small editor for the selected capture, without leaving the overlay. You can add arrows, rectangles and text, crop, change color, undo and redo, then copy, save, or both. Every action works from the keyboard alone and from the mouse alone.

The goal is met when you can capture, add an arrow and a label, and copy the result without touching the mouse, in a few seconds. Plain ↵ stays the instant copy it is today.

## Decisions

- **In place.** The captured image is frozen exactly over its target on the existing overlay panels. There is no separate editor window. Capture filters already leave Vishot's windows out (window and element captures use `desktopIndependentWindow`, display captures exclude Vishot), so the panels stay up during the capture and nothing flickers.
- **Aiming with a cursor only.** A crosshair moved with `hjkl` and jumps. There is no hint grid.
- **v1 scope:** arrow, rectangle, text, crop, color cycling, undo and redo, copy, save, save and copy, save as.
- **Every finishing action closes the editor and the overlay.**
- **Instant save** to the macOS screenshot folder as `vishot-YYYY-MM-DD-HHmmss.png`. `⌘s` opens a save panel instead.
- **Full mouse parity** through a clickable toolbar and dragging.

## Flow

1. In Window, Element or Screen mode, ⇧↵ (or ⇧Space) calls `OverlayController.edit()`.
2. The selection border stays and the status line shows "capturing…" while `Capturer.image(for:)` runs, usually 50–150 ms.
3. The frozen image is placed at the target's frame as it was when the capture finished. The rest of every screen is dimmed and the HUD becomes the editor toolbar.
4. Keys and mouse events go to `EditorController` until it finishes.
5. When it finishes, the overlay hides, then the capturer copies or saves the exported image.

## Keys

The cursor is a drawn crosshair. It starts at the image's center and is clamped to the image (the full image, not the crop).

| Keys | Action |
|---|---|
| `hjkl` / arrows | move 8 pt |
| `⇧hjkl` / ⇧arrows | move 64 pt |
| `⌥hjkl` / ⌥arrows | move 1 pt |
| `0` / `$` | left / right edge |
| `g` / `G` | top / bottom edge |
| `M` | center |
| `a` | arrow tool, tail anchored at the cursor |
| `r` | rectangle tool, corner anchored at the cursor |
| `c` | crop tool, corner anchored at the cursor |
| `t` | text tool, caret at the cursor |
| `↵` / tool key again | finish the anchored arrow, rectangle or crop at the cursor |
| `tab` / `⇧tab` | next / previous color |
| `u`, `⌘z` | undo |
| `⌃r`, `⇧⌘z` | redo |
| `y` | copy, close |
| `s` | save, close |
| `S` | save and copy, close |
| `⌘s` | save panel, close |
| `esc` / `q` | discard and close. With annotations or a crop, the first press shows "esc again to discard" |
| `esc` during an action | cancel that action |

All keys match by key code (`kVK_*`), like the overlay. The exception is typing text, which reads `event.characters`, so any layout types normally. Text is one line. `⌫` deletes, `↵` places it, and `esc` cancels it.

Colors: red (default), yellow, green, blue, white, black. The HUD status line shows the current color.

## Mouse

- **Toolbar.** On the editing screen the HUD is replaced by a toolbar with buttons for arrow, rect, text and crop, six color swatches, undo, redo, copy, save, save and copy, save as, and discard. Each button shows its key. The toolbar goes below the image if there is room, otherwise above it, and otherwise floats inside the bottom edge (display captures).
- **Current tool.** There is always one, arrow by default, highlighted in the toolbar. Clicking a tool button only selects the tool. The tool keys select it and also anchor it at the cursor.
- **Drawing.** Dragging on the image draws with the current tool, from mouse-down to mouse-up. A drag shorter than 3 pt is a click. A click places the caret for the text tool. With another tool, a click acts like `↵` (it finishes an anchored action and does nothing otherwise).
- **One cursor.** Mouse moves put the crosshair under the pointer. Keyboard moves call `NSCursor.setHiddenUntilMouseMoves(true)`. Keyboard and mouse can be mixed within one action.
- **Outside the image.** A click on the dimmed area does nothing.

## Components

### `Annotation.swift` (pure, tested)

- `enum Annotation { case arrow(from: CGPoint, to: CGPoint, color: AnnotationColor); case rect(CGRect, color:); case text(String, at: CGPoint, color:) }`.
- Image space means points from the image's top-left, with y down. The model never stores screen positions.
- `struct EditDocument { let image: CGImage; let scale: CGFloat; var annotations: [Annotation]; var crop: CGRect? }`. `size` is the pixel size divided by `scale`.
- `struct EditHistory`: undo and redo stacks of `(annotations, crop)` snapshots. A change pushes a snapshot and clears redo. Undo or redo with nothing to apply returns false, and the caller beeps.
- `struct EditCursor`: position, clamping to a size, step moves, and edge and center jumps.
- `CGRect(corners:)` normalizes rectangles drawn in any direction.

### `AnnotationRenderer.swift`

- `draw(_ annotations: [Annotation], in: CGContext)` draws in image space.
  - Arrow: a 4 pt stroke with round caps and a filled triangle head.
  - Rect: a 4 pt stroke with no fill.
  - Text: bold 20 pt in the annotation color, with a 3 pt halo (white, or black for white text).
  - Everything gets a light 1 pt shadow.
- `export(_ doc: EditDocument) -> CGImage?` makes a bitmap context at pixel size scaled by `scale`. It draws the image and the annotations, then crops to `crop × scale` rounded to whole pixels and clamped to the image.
- The on-screen layers call `draw`, so what you see matches the export.

### `Editor.swift`: `EditorController`

- **State:** document, history, cursor, current tool, current color, `imageOrigin` (CG global), the "esc again" flag, and the action in progress: `.idle`, `.anchored(start)`, `.dragging(start)`, or `.typing(text, at)`.
- **Input:** `handle(_ event: NSEvent)`, `mouseMoved`, `mouseDown`, `mouseDragged` and `mouseUp`, all with CG-global points converted with `imageOrigin`. Toolbar hits come in as `ToolbarItem`s.
- **Output:** `render(on panels:)` and `onFinish: (Finish) -> Void`, where `enum Finish { case copy, save, saveAndCopy, saveAs, discard }`. The callback is `(Finish, (image: CGImage, scale: CGFloat)?)`. The image is exported before `onFinish` is called, and it is nil only for `.discard`.
- **Ignored with a beep, and no snapshot:** an empty crop, a zero-length arrow or rect, undo or redo with nothing to apply.
- An empty text label is cancelled.

### `EditorLayer.swift`: per-panel layers

Each `OverlayPanel` creates one with the panel, hidden until editing. It contains:

- A frozen image layer (`contents` = the capture) at the image's global rect, clipped to the panel like `highlight`.
- A dim `CAShapeLayer` with an even-odd path: 45% black outside the image and 70% outside the crop.
- An annotations layer whose `draw(in:)` calls `AnnotationRenderer.draw` with the panel's offset. It holds the committed annotations plus a live preview of the action in progress.
- The crosshair, the text caret, and the toolbar. The toolbar is built from CALayers in the HUD style and hit-tests a point into a `ToolbarItem?`.

### Changes to existing code

- **`Capturer`.**
  - `capture(_:)` splits into `image(for: CaptureTarget) async -> (CGImage, CGFloat)?` and `copy(_:scale:)`. The ↵ path keeps its behavior: capture after hiding, lazy pasteboard provider.
  - New `save(_:scale:to:)` encodes the PNG with the DPI tag on a background queue. PNG and DPI encoding move into one helper, shared with `ImageProvider`.
- **`OverlayController`.**
  - `private var editor: EditorController?`.
  - ⇧↵ / ⇧Space call `edit()`.
  - `handle`, the mouse callbacks and `render` forward to the editor while it exists.
  - `hide()` clears it.
  - `onFinish` hides the overlay, then copies or saves.
  - `.saveAs` calls `NSApp.activate(ignoringOtherApps:)`, then runs `NSSavePanel` with the default name in the save folder. On cancel it reshows the overlay with the same editor state.
  - Mode HUD strings gain `⇧↵ edit`.
- **`OverlayPanel`.** Owns an `EditorLayer`, adds `onMouseDragged` and `onMouseUp`, and hides the mode HUD while the toolbar shows.
- **`Config`.**
  - `saveFolder() -> URL` reads `com.apple.screencapture`'s `location` default (with `~` expanded) and falls back to `~/Desktop`.
  - `fileName(for: Date) -> String` gives `vishot-2026-10-03-142205.png`, in local time.

## Errors and edge cases

- **The capture fails or the window is gone:** beep, show "capture failed", stay in the picker.
- **`s` / `S` write in the background after the overlay hides.** If the write fails: beep, `NSLog` the error, and put the image on the clipboard so the edit isn't lost. The close path never waits on PNG encoding.
- **The save panel is cancelled:** go back to the editor with its state intact.
- **Screen parameters change, the hotkey is pressed, or another app takes key focus:** `hide()` discards the edit, as it cancels the picker today.
- **The off-screen part of a window** cannot be annotated, but it is in the export.
- **Element captures** can only be annotated within the element.
- **Composing input methods** (Chinese, Japanese) do not work in text labels in v1, because typing reads `event.characters`.
- **Pointer hiding** from a non-activating panel of an inactive accessory app may not work. If it doesn't, the system pointer stays visible and the drawn crosshair is still the one that counts.

## Performance

Nothing here runs before ⇧↵. Each panel gains one hidden sublayer tree, built with the panel, so showing the overlay costs the same as before. Export and PNG encoding happen only on finish. Copy stays lazy through the pasteboard provider.

## Testing

**Unit tests (XCTest):**
- `EditHistory`: push, undo and redo, push clears redo, undo or redo when empty.
- `EditCursor`: clamping, step sizes, edge and center jumps.
- `CGRect(corners:)` for all four directions, and the click threshold.
- Export: pixel crop rect at scale 1 and 2, and output size for a cropped 4×4 image.
- `Config.fileName(for:)` with a fixed date and time zone.

**By hand on the installed app** (`./scripts/build.sh install`):
- Window, element and display captures.
- A window spanning two screens.
- Keyboard-only and mouse-only runs of every tool and finishing action.
- A non-Latin layout for keys, and Cyrillic text in labels.
- Pointer hiding.
- The save panel round trip, including cancel.
- A failed save falling back to the clipboard.

**Docs:** add the editor to `CLAUDE.md` (architecture bullets and flow) and to the README usage section.
