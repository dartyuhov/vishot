# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Vishot is a macOS 14+ menu-bar app (`LSUIElement`, accessory activation policy) for keyboard-first window screenshots: a global hotkey (⇧⌘2) opens an overlay, `hjkl`/arrows/Tab pick a window, Return copies it to the clipboard. It is a SwiftPM executable with no dependencies, tests, or linter.

## Commands

```sh
swift build                    # quick compile check (debug)
./scripts/build.sh             # release build → build/Vishot.app, codesigned
./scripts/build.sh install     # also copy to ~/Applications/Vishot.app, kill the old instance, relaunch
```

- The `.app` bundle is assembled by hand in `scripts/build.sh` (binary + `Resources/Info.plist`); there is no Xcode project. Bundle metadata lives in `Resources/Info.plist`.
- Signing uses the `Apple Development` identity by default (`VISHOT_SIGN_IDENTITY` overrides). A stable signature is what keeps the Screen Recording (TCC) permission across rebuilds, so don't switch to ad-hoc signing.
- Running the raw binary from `swift build` works for quick checks, but screen capture permission is tied to the signed bundle. Test captures with the installed app.
- Swift tools 6.0, but the target is built in Swift 5 language mode (`.swiftLanguageMode(.v5)`), so strict concurrency checking is off.

## Architecture

Flow: `main.swift` → `AppDelegate` registers a `HotKey` and status-bar menu → `OverlayController.toggle()` → `WindowCatalog.visibleWindows()` lists windows → key presses go to `Navigator` → on confirm, `Capturer` grabs the window and puts it on the pasteboard.

- **`HotKey`**: Carbon `RegisterEventHotKey` (no Accessibility permission needed). The hotkey is configured in `Config` in `AppDelegate.swift`. The status-menu key equivalent is hard-coded separately, so update both.
- **`WindowCatalog`**: uses `CGWindowListCopyWindowInfo` because it is much faster than AX/ScreenCaptureKit. It keeps only layer-0 windows from `.regular` activation-policy apps, which drops overlay agents like JankyBorders. For each window it samples a 12×12 grid, minus the screens it is off and the windows in front of it, to compute a visible-area `anchor`. Windows with fewer than 4 visible samples are dropped, which removes fully covered windows and AeroSpace's off-screen parked windows. The result is ordered front to back.
- **`Navigator`**: directional neighbor search from anchor to anchor. Candidates that overlap the current window on the perpendicular axis (tiled neighbors) always rank above diagonal ones.
- **`OverlayController` / `OverlayPanel`**: one borderless non-activating `NSPanel` per screen at `.screenSaver` level. Panels are built once and rebuilt only when screen parameters change. Moving the selection only repositions CALayers inside a `CATransaction` with actions disabled. Every panel gets the same global rect and clips it to its own screen. The first panel takes key focus. Keys are matched by **key code** (`kVK_*`), not by character, so they work with non-Latin layouts. Losing key status cancels the picker.
- **`Capturer`**: `prefetch()` starts `SCShareableContent` loading when the overlay opens, hiding its latency behind the selection time. `capture()` runs a single-window `SCScreenshotManager.captureImage` after the overlay hides. The pasteboard gets a lazy `NSPasteboardItemDataProvider`, so PNG/TIFF encoding with Retina DPI tagging happens only on paste. The provider must stay retained (`Capturer.provider`).

### Coordinate spaces

`WindowInfo.frame`/`anchor` and all catalog/navigation math use **CoreGraphics global space** (top-left origin of the primary display, y down). AppKit panels and `NSScreen.frame` use **Cocoa space** (bottom-left origin). Convert with `CGRect.flippedBetweenCocoaAndCG` (its own inverse) and `NSScreen.cgFrame`, both defined in `WindowCatalog.swift`.

### Performance

Latency is the main design constraint, and the README's "Speed notes" describe the intended trade-offs. Keep the hotkey-to-overlay path free of ScreenCaptureKit/AX calls, per-show allocations of windows, and eager image encoding.
