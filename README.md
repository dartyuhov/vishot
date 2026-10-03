# Vishot

Keyboard-first screenshots for macOS. Press a hotkey, pick a window, a UI element, or a whole display with `hjkl`, and the image is on the clipboard.

## Usage

`⇧⌘2` opens the picker in Window mode (press it again to cancel). A HUD at the bottom of the screen shows the current mode and its keys.

| Key | Window (default) | Element | Screen |
|---|---|---|---|
| `h` `j` `k` `l` / arrows | nearest window in that direction, across all screens | nearest sibling element | nearest display |
| `Tab` / `⇧Tab` | cycle windows front to back | cycle siblings | cycle displays |
| `Return` / `Space` | copy the window | copy the element | copy the display |
| `v` | elements of the selected window | | |
| `i` / `o` | | into the element / out to its parent | |
| `f` | label elements (enters Element mode) | label elements | |
| `G` (`⇧g`) | Screen mode | Screen mode | |
| `Esc` | cancel | back to Window | back to Window |
| `q` | cancel | cancel | cancel |

`Esc Esc` always quits (one more `Esc` if hint labels are showing). The mouse works too: hover selects, click copies. In Element mode, hover selects the deepest element under the cursor; press `o` to widen to its parent.

**Hints**: `f` puts a short label on every element up to three levels below the current one (messages, buttons, fields, panes). Elements that contain others get an outline in the same color as their label; single elements (buttons, text) have plain yellow labels. Type a label to select its element, then `↵` to copy it. `⌫` undoes a letter, `Esc` hides the labels.

The picker starts on the focused app's window. Hidden windows (fully covered, or parked off-screen by AeroSpace) are skipped.

Element mode needs the Accessibility permission. Vishot asks for it the first time you press `v`, never at launch. Wrapper groups are skipped automatically: an element that is alone in its level, or covers most of it, is replaced by its children. So the main regions of a window (sidebar, toolbar, content) are the first level, and one `i` reaches items such as individual messages. In Chromium browsers and Electron apps, Vishot turns on their accessibility trees the first time you browse them; the HUD shows `loading page…` for up to 3 s while they build.

## Build

```sh
./scripts/build.sh           # build/Vishot.app
./scripts/build.sh install   # copy to ~/Applications and relaunch
swift test                   # unit tests for navigation, element filtering, and crop math
```

Builds are signed with your `Apple Development` certificate (override with `VISHOT_SIGN_IDENTITY`), so the Screen Recording and Accessibility permissions survive rebuilds.

Change the hotkey in `Config` in `Sources/Vishot/AppDelegate.swift`.

## Speed notes

- Windows are listed with `CGWindowList` (~1 ms) rather than Accessibility or ScreenCaptureKit.
- Overlay panels are created once per screen and reused; moving the selection only moves a layer.
- `SCShareableContent` is fetched while you choose, then a single-window or single-display capture runs after the overlay closes.
- Accessibility is only touched after `v`, and only one level of the tree is loaded at a time (a few ms).
- The clipboard holds a lazy provider; PNG/TIFF encoding happens only when something pastes.
