# Vishot

Keyboard-first window screenshots for macOS. Press a hotkey, pick a window with `hjkl`, and the image is on the clipboard.

## Usage

| Key | Action |
|---|---|
| `⇧⌘2` | Open the window picker (press again to cancel) |
| `h` `j` `k` `l` / arrows | Move to the nearest window in that direction, across all screens |
| `Tab` / `⇧Tab` | Cycle windows front to back |
| `Return` / `Space` | Copy the selected window to the clipboard |
| `Esc` / `q` | Cancel |

The picker starts on the focused app's window. Hidden windows (fully covered, or parked off-screen by AeroSpace) are skipped.

## Build

```sh
./scripts/build.sh           # build/Vishot.app
./scripts/build.sh install   # copy to ~/Applications and relaunch
```

Builds are signed with your `Apple Development` certificate (override with `VISHOT_SIGN_IDENTITY`), so the Screen Recording permission survives rebuilds.

Change the hotkey in `Config` in `Sources/Vishot/AppDelegate.swift`.

## Speed notes

- Windows are listed with `CGWindowList` (~1 ms) rather than Accessibility or ScreenCaptureKit.
- Overlay panels are created once per screen and reused; moving the selection only moves a layer.
- `SCShareableContent` is fetched while you choose, then a single-window capture runs after the overlay closes.
- The clipboard holds a lazy provider; PNG/TIFF encoding happens only when something pastes.
