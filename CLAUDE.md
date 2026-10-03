# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Vishot is a macOS 14+ menu-bar app (`LSUIElement`, accessory activation policy) for keyboard-first screenshots: a global hotkey (⇧⌘2) opens an overlay, `hjkl`/arrows/Tab pick a window, Return copies it to the clipboard. `v` switches to Element mode (UI elements inside the window, over Accessibility) and `G` to Screen mode (whole displays). It is a SwiftPM executable with no dependencies and no linter.

## Commands

```sh
swift build                    # quick compile check (debug)
swift test                     # XCTest unit tests (VishotTests)
./scripts/build.sh             # release build → build/Vishot.app, codesigned
./scripts/build.sh install     # also copy to ~/Applications/Vishot.app, kill the old instance, relaunch
```

- The `.app` bundle is assembled by hand in `scripts/build.sh` (binary + `Resources/Info.plist`); there is no Xcode project. Bundle metadata lives in `Resources/Info.plist`.
- Signing uses the `Apple Development` identity by default (`VISHOT_SIGN_IDENTITY` overrides). A stable signature is what keeps the Screen Recording (TCC) permission across rebuilds, so don't switch to ad-hoc signing.
- Running the raw binary from `swift build` works for quick checks, but screen capture permission is tied to the signed bundle. Test captures with the installed app.
- Swift tools 6.0, but the targets are built in Swift 5 language mode (`.swiftLanguageMode(.v5)`), so strict concurrency checking is off.
- Tests cover pure logic only (`Navigator`, `ElementFilter`, `HintLabels`, `Capturer.cropRect`). AX, ScreenCaptureKit, and overlay behavior are checked by hand on the installed app.
- Element mode needs the Accessibility permission, which, like Screen Recording, is tied to the stable signature.

## Architecture

Flow: `main.swift` → `AppDelegate` registers a `HotKey` and status-bar menu → `OverlayController.toggle()` → `WindowCatalog.visibleWindows()` lists windows → key presses and mouse events go to `OverlayController`, which navigates `[CaptureTarget]` with `Navigator` → on confirm, `Capturer` grabs the target and puts it on the pasteboard.

- **`CaptureTarget`**: what every mode selects: a window, an element (window ID plus rect clipped to the window), or a display. `WindowInfo.target` and `DisplayCatalog.displays()` produce window and display targets.
- **`HotKey`**: Carbon `RegisterEventHotKey` (no Accessibility permission needed). The hotkey is configured in `Config` in `AppDelegate.swift`. The status-menu key equivalent is hard-coded separately, so update both.
- **`WindowCatalog`**: uses `CGWindowListCopyWindowInfo` because it is much faster than AX/ScreenCaptureKit. It keeps only layer-0 windows from `.regular` activation-policy apps, which drops overlay agents like JankyBorders. For each window it samples a 12×12 grid, minus the screens it is off and the windows in front of it, to compute a visible-area `anchor`. Windows with fewer than 4 visible samples are dropped, which removes fully covered windows and AeroSpace's off-screen parked windows. The result is ordered front to back.
- **`Navigator`**: directional neighbor search from anchor to anchor, over target indices. Candidates that overlap the current target on the perpendicular axis (tiled neighbors) always rank above diagonal ones.
- **`ElementCatalog` / `ElementFilter`**: Element mode. The AX window is found by `CGWindowID` through the private `_AXUIElementGetWindow`, with a frame-match fallback. Every app element gets a 0.25 s messaging timeout. Only one level (the children of the current element) is loaded per `v`/`i`/`o`. `ElementFilter` is the pure part, over the `ElementNode` protocol. It drops window-button, `AXEmptyGroup`, childless background, and empty untitled-group nodes. Tiny or frameless nodes are dropped too, but their children are hoisted into the level, because Slack's message list is a 1×1 screen-reader-only node. A node alone in its level, or covering ≥ 80% of the level's root, is replaced by its children (up to 30 steps, never into an empty level). A lone child with the root's own frame is not a level. `ElementFilter.path(to:)` (hover) and `hintPaths` (hint labels, skipping containers ≥ 40% of the root) walk several levels through a loader closure, so `OverlayController` can serve them from its per-window level cache. The first time Element mode touches an app it sets `AXManualAccessibility` (Electron) and, for Chromium windows (`BrowserRootView` DOM class), `AXEnhancedUserInterface`. Chrome reports an error for the latter even though it works, so the result is ignored. The level then reloads every 100 ms for 3 s while the tree builds. `ElementCatalog.restoresEnhancedUserInterface` controls whether the Chromium flag is turned back off when the overlay closes. It is off by default because re-enabling costs ~2 s.
- **`OverlayController`**: owns the mode (Window, Element, Hint, Screen), the current targets and selection, and the element level stack, which saves the selection per level so `o` restores it. Hover in Element mode and hint labels build the whole stack, so `o` and `hjkl` work from wherever they land. Loaded levels are cached per window, because hover walks the tree on every mouse move; the cache is dropped on window change and on warm-up reloads. It dispatches keys and mouse events. Hint labels (`HintLabels`) are matched by key code, like every other key.
- **`OverlayPanel`**: one borderless non-activating `NSPanel` per screen at `.screenSaver` level. Panels are built once and rebuilt only when screen parameters change. Moving the selection only repositions CALayers inside a `CATransaction` with actions disabled. Every panel gets the same global rect and clips it to its own screen. A target touching the screen edge draws its border inset. The HUD (mode keys plus a status line) shows only on the panel whose screen holds the selection's anchor. The first panel takes key focus. Keys are matched by **key code** (`kVK_*`), not by character, so they work with non-Latin layouts. Panels take mouse events. Their background has 1% alpha, because fully transparent pixels pass clicks through, and an `.activeAlways` tracking area provides hover on non-key screens. Losing key status cancels the picker, unless the key focus moved to another of our panels.
- **`Capturer`**: `prefetch()` starts `SCShareableContent` loading when the overlay opens, hiding its latency behind the selection time. `capture(_:)` runs `SCScreenshotManager.captureImage` after the overlay hides: single window, single window cropped to an element (using `SCWindow.frame` at capture time), or a display excluding Vishot's own windows. The pasteboard gets a lazy `NSPasteboardItemDataProvider`, so PNG/TIFF encoding with Retina DPI tagging happens only on paste. The provider must stay retained (`Capturer.provider`).

### Coordinate spaces

`CaptureTarget.frame`/`anchor`, AX positions, and all catalog/navigation math use **CoreGraphics global space** (top-left origin of the primary display, y down). AppKit panels, `NSScreen.frame`, and `NSEvent.mouseLocation` use **Cocoa space** (bottom-left origin). Convert with `CGRect`/`CGPoint.flippedBetweenCocoaAndCG` (each its own inverse) and `NSScreen.cgFrame`, all defined in `WindowCatalog.swift`.

### Performance

Latency is the main design constraint, and the README's "Speed notes" describe the intended trade-offs. Keep the hotkey-to-overlay path free of ScreenCaptureKit/AX calls, per-show allocations of windows, and eager image encoding. AX runs only after `v`, `i`, `o`, or a hover onto another window in Element mode. `DisplayCatalog` runs only on `G`.
