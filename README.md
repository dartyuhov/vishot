# Vishot

Keyboard-first screenshots for macOS. Press a hotkey, pick a window or a whole display with `hjkl` (or a UI element by its label, or any region), and the image is on the clipboard. Or press `⇧Return` to add arrows, boxes and labels first.

## Usage

`⇧⌘S` opens the picker in Window mode (press it again to cancel). A HUD at the bottom of the screen shows the current mode and its keys.

| Key | Window (default) | Element | Screen |
|---|---|---|---|
| `h` `j` `k` `l` / arrows | nearest window in that direction, across all screens | | nearest display |
| `Tab` / `⇧Tab` | cycle windows front to back | | cycle displays |
| `Return` / `Space` | copy the window | copy the element | copy the display |
| `⇧Return` / `⇧Space` / `e` | edit the window | edit the element | edit the display |
| `f` | label the window's elements | label the window's elements again | |
| `G` (`⇧g`) | Screen mode | Screen mode | |
| `v` | Region mode | Region mode | Region mode |
| `Esc` | cancel | back to Window | back to Window |
| `q` | cancel | cancel | cancel |

`Esc Esc` always quits. The mouse works too: in Window and Screen mode hover selects and click copies; in Element mode a click on the element copies it.

**Elements**: `f` puts a short label on the elements of the selected window that are worth a screenshot alone: messages, panes, toolbars, fields. Elements smaller than 24 pt on a side or 1% of the window (icon buttons, emoji, timestamps) get none, and neither does an element that nearly fills a labelled one. Elements that contain others get an outline in the same color as their label; single elements have plain yellow labels. Type a label to select its element (Element mode), then `↵` to copy it. `⌫` undoes a letter, `Esc` hides the labels.

**Region**: `v` selects any rectangle on one display, like a crop in the editor. A crosshair starts on the current selection and moves with the editor's keys: `hjkl` or arrows (hold to glide, `⇧` far, `⌥` slow) and `0` `$` `g` `G` `M` to jump to the display's edges and center. `v` sets the first corner and `v` again the opposite one; or drag with the mouse. The region stays, with its size as the label and the rest dimmed, until you draw another. `Return` copies it (finishing a region still being drawn), `⇧Return` or `e` edits it, and a click inside it copies too. `Tab` moves the crosshair to the next display, and `Esc` drops a corner, then goes back to Window mode.

**Editor**: `⇧Return` freezes the selection in place, dims everything else, and shows a toolbar. A crosshair cursor starts at the image's center.

| Key | Action |
|---|---|
| `h` `j` `k` `l` / arrows | a tap moves the cursor 15 pt (`⇧` 48 pt, `⌥` 6 pt); holding glides and speeds up, and two keys held (`k` + `l`) move diagonally |
| `0` / `$`, `g` / `G`, `M` | left / right edge, top / bottom edge, center |
| `a` / `r` / `c` | start an arrow / rectangle / crop at the cursor; move, then `Return` or the same key to finish |
| `t` | type a one-line label at the cursor; `Return` or `Esc` places it, `⌘Z` cancels |
| `1`…`6`, `Tab` / `⇧Tab` | pick a color (red, yellow, green, blue, white, black; the numbers are on the toolbar swatches), next / previous color |
| `u` or `⌘Z` / `⌃R` or `⇧⌘Z` | undo / redo |
| `y` | copy and close |
| `s` / `S` | save / save and copy, then close |
| `⌘S` | save as… |
| `Esc` / `q` | finish the current shape, or discard (press twice if anything was drawn); `u` cancels a shape in progress |

Saves go to the macOS screenshot folder (the Screenshot app's "Save to" option, else the Desktop) as `vishot-2026-10-03-142205.png`. Everything works with the mouse too: drag on the image to draw with the current tool, click to place a label with the text tool, and use the toolbar for tools, colors, undo and finishing.

The picker starts on the focused app's window. Hidden windows (fully covered, or parked off-screen by AeroSpace) are skipped.

Labels need the Accessibility permission. Vishot asks for it the first time you press `f`, never at launch. Wrapper groups that would capture the same image as their parent get no label. In Chromium browsers and Electron apps, Vishot turns on their accessibility trees the first time you label them; the HUD shows `loading page…` and labels appear for up to 3 s while they build.

## Build

```sh
./scripts/build.sh           # build/Vishot.app
./scripts/build.sh install   # copy to ~/Applications and relaunch
swift test                   # unit tests for navigation, element filtering, crop math, region selection, and the editor model
```

Builds are signed with your `Apple Development` certificate (override with `VISHOT_SIGN_IDENTITY`), so the Screen Recording and Accessibility permissions survive rebuilds.

Change the hotkey in `Config` in `Sources/Vishot/AppDelegate.swift`.

## Speed notes

- Windows are listed with `CGWindowList` (~1 ms) rather than Accessibility or ScreenCaptureKit.
- Overlay panels are created once per screen and reused; moving the selection only moves a layer.
- `SCShareableContent` is fetched while you choose, then a single-window or single-display capture runs after the overlay closes.
- Accessibility is only touched after `f`. The walk skips everything inside elements too small to label (~20–30 ms for Slack or a browser).
- The clipboard holds a lazy provider; PNG/TIFF encoding happens only when something pastes.
- Region mode reads the displays only on `v`, and captures only the display holding the region.
- The editor costs nothing until `⇧Return`: its layers are built with the panels, and the export is drawn only when you finish.
