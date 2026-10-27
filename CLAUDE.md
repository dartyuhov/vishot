# CLAUDE.md

This file provides guidance to coding agents working in this repository.

Vishot is a macOS 14+ menu-bar app (`LSUIElement`, accessory activation policy) for keyboard-first screenshots: a global hotkey (⇧⌘S) opens an overlay, `hjkl`/arrows/Tab pick a window, Return copies it to the clipboard. `f` labels the window's UI elements over Accessibility, and typing a label selects one (Element mode) and `G` to Screen mode (whole displays). `v` enters Region mode, which selects any rectangle on one display with the editor's cursor keys or a mouse drag. ⇧Return or `e` opens an in-place editor (arrows, rectangles, text, crop) before copying or saving. It is a SwiftPM package with an app, a bundled CLI, shared modules, a locked TOMLKit dependency, and no linter.

## Commands

```sh
swift build                    # quick compile check (debug)
swift test                     # all five XCTest targets
./scripts/build.sh             # release build → build/Vishot.app, codesigned
./scripts/build.sh install     # also copy to ~/Applications/Vishot.app, kill the old instance, relaunch
```

- The `.app` bundle is assembled by hand in `scripts/build.sh` (binary + `Resources/Info.plist`); there is no Xcode project. Bundle metadata lives in `Resources/Info.plist`.
- Signing uses the `Apple Development` identity by default (`VISHOT_SIGN_IDENTITY` overrides). A stable signature is what keeps the Screen Recording (TCC) permission across rebuilds, so don't switch to ad-hoc signing.
- Running the raw binary from `swift build` works for quick checks, but screen capture permission is tied to the signed bundle. Test captures with the installed app.
- Swift tools 6.0, but the targets are built in Swift 5 language mode (`.swiftLanguageMode(.v5)`), so strict concurrency checking is off.
- Tests cover pure logic, shared modules, compiled CLI boundaries, and app integration. AX, ScreenCaptureKit, overlay, and editor runtime behavior also need manual checks on the signed app.
- Hints need the Accessibility permission, which, like Screen Recording, is tied to the stable signature.

## Landing site

`site/` is vishot.dev: a static landing page plus a dependency-free Node 24 server with allowlisted assets and cached public GitHub metadata. It has no database, signup intake, or subscriber export.

```sh
cd site && npm test            # node:test suite; exercises served routes and metadata
cd site && npm start           # http://localhost:3000; no storage required
```

- Deploys are Railway's GitHub autodeploy (project `vishot`, service `site`): a push to `main` that touches `site/**` deploys once the `Site` workflow passes ("Wait for CI"). The service uses root directory `site`, start `node server.js`, health check `/healthz`, and watch path `/site/**`. Node's version is in `site/.node-version`, which CI reads too.
- Installation controls require `VISHOT_INSTALL_READY=true` and verified complete public release/tap metadata. For metadata contracts and storage archival/hosting cleanup, read `docs/site-operations.md`. Archived subscriber files remain untouched; the runtime needs no volume or export credentials.
- The `App` workflow runs `swift test` on macOS for changes under `Sources/`, `Tests/` or `Package.swift`.

## Shared modules and CLI

For CLI command changes, shared rendering/configuration changes, or test moves,
read `CONTRIBUTING.md` ("Shared modules and test ownership") and
`docs/agent-cli.md`. `VishotCLIExecution` owns in-process annotation and command
semantics; `VishotRendering` owns screenshot drawing, fonts, and encoding;
`VishotConfiguration` owns full immutable TOML interpretation. The app owns
GUI styling, live Settings, and signed capture. Font registration takes an
explicit resource directory and precedes treatment resolution. Bundled CLI
annotation rejects missing fonts; raw app development builds retain fallback.
The package has TOMLKit as a locked dependency; tests span five SwiftPM targets,
including compiled CLI and app integration checks, not only pure logic.

## Architecture

Flow: `main.swift` → `AppDelegate` registers a `HotKey` and status-bar menu → `OverlayController.toggle()` → `WindowCatalog.visibleWindows()` lists windows → key presses and mouse events go to `OverlayController`, which navigates `[CaptureTarget]` with `Navigator` → on confirm, `Capturer` grabs the target and puts it on the pasteboard. On ⇧↵ (`edit()`), `Capturer.image(for:)` captures with the overlay still up, an `EditorController` takes over keys and mouse events, and its `onFinish` hides the overlay, then copies or saves the exported image.

- **`CaptureTarget`**: what every mode selects: a window, an element (window ID plus rect clipped to the window), or a display. `WindowInfo.target` and `DisplayCatalog.displays()` produce window and display targets.
- **`HotKey`**: Carbon `RegisterEventHotKey` (no Accessibility permission needed). The hotkey is configured in `Config` in `AppDelegate.swift`. The status-menu key equivalent is hard-coded separately, so update both.
- **`WindowCatalog`**: uses `CGWindowListCopyWindowInfo` because it is much faster than AX/ScreenCaptureKit. It keeps only layer-0 windows from `.regular` activation-policy apps, which drops overlay agents like JankyBorders. For each window it samples a 12×12 grid, minus the screens it is off and the windows in front of it, to compute a visible-area `anchor`. Windows with fewer than 4 visible samples are dropped, which removes fully covered windows and AeroSpace's off-screen parked windows. The result is ordered front to back.
- **`Navigator`**: directional neighbor search from anchor to anchor, over target indices. Candidates that overlap the current target on the perpendicular axis (tiled neighbors) always rank above diagonal ones.
- **`ElementCatalog` / `ElementFilter`**: hints. The AX window is found by `CGWindowID` through the private `_AXUIElementGetWindow`, with a frame-match fallback. Every app element gets a 0.25 s messaging timeout. `ElementFilter` is the pure part, over the `ElementNode` protocol. It drops window-button, `AXEmptyGroup`, childless background, and empty untitled-group nodes. Tiny or frameless nodes are dropped too, but their children are hoisted into the level, because Slack's message list is a 1×1 screen-reader-only node. A node alone in its level, or covering ≥ 80% of the level's root, is replaced by its children (up to 30 steps, never into an empty level). A lone child with the root's own frame is not a level. `ElementFilter.hints` walks levels to any depth (capped at 300 hints) and puts hints on elements at least 24 pt on a side and 1% of the window; it doesn't descend below smaller ones. A leaf covering ≥ 85% of its nearest hinted ancestor shares that hint (Slack's message text fills its message). The thresholds were tuned on live Slack, Helium and Obsidian trees. The first time `f` touches an app it sets `AXManualAccessibility` (Electron) and, for Chromium windows (`BrowserRootView` DOM class), `AXEnhancedUserInterface`. Chrome reports an error for the latter even though it works, so the result is ignored. The hints then reload every 250 ms for 3 s while the tree builds, until a letter is typed. `ElementCatalog.restoresEnhancedUserInterface` controls whether the Chromium flag is turned back off when the overlay closes. It is off by default because re-enabling costs ~2 s.
- **`OverlayController`**: owns the mode (Window, Hint, Element, Screen, Region), the current targets and selection. Hint mode keeps the window selected under the hints; typing a hint enters Element mode with that element as the only target. It dispatches keys and mouse events. Hints (`Hints`) are matched by key code, like every other key.
- **`WindowRaiser`**: in Window mode, moving the selection (`hjkl`/arrows/Tab) brings the window to the front so a covered one is visible. `AXRaise` alone only puts a window just below the active app's front window, so the window's app is activated too. Vishot waits until the window is actually in front (polling `CGWindowList`), then reactivates itself to get key focus back; reactivating sooner cancels the switch. Meanwhile a session event tap swallows keys and passes them to `OverlayController`, so they don't reach the raised app, and `isSwitchingApps` keeps `windowDidResignKey` from cancelling. Raises run on a serial queue, and moves faster than raises skip the windows in between. Apps handle `AXRaise` asynchronously, so `hide()` restores the stacking one window at a time: it reactivates the original front window, then raises the windows that were in front of the lowest raised one, back to front, waiting for each to land. Mouse hover doesn't raise, and the anchors aren't recomputed. Fully covered windows aren't in the catalog, so they can't be reached. Without the Accessibility permission it does nothing.
- **`OverlayPanel`**: one borderless non-activating `NSPanel` per screen at `.screenSaver` level. Panels are built once and rebuilt only when screen parameters change. Moving the selection only repositions CALayers inside a `CATransaction` with actions disabled. Every panel gets the same global rect and clips it to its own screen. A target touching the screen edge draws its border inset. The border is pixel art like the logo: a 4 pt ring with a 4 pt square left out of each corner. The HUD shows only on the panel whose screen holds the selection's anchor: the mode's name, its `HUDKey`s as keycaps (laid out again only when the mode changes), and a status line. `HUD.swift` holds that look (panel style, name, keycaps, entries, text baseline snapping), which the editor's toolbar shares. The first panel takes key focus. Keys are matched by **key code** (`kVK_*`), not by character, so they work with non-Latin layouts. Panels take mouse events. Their background has 1% alpha, because fully transparent pixels pass clicks through, and an `.activeAlways` tracking area provides hover on non-key screens. Losing key status cancels the picker, unless the key focus moved to another of our panels.
- **`Capturer`**: `prefetch()` starts `SCShareableContent` loading when the overlay opens, hiding its latency behind the selection time. `image(for:)` runs `SCScreenshotManager.captureImage`: single window, single window cropped to an element (using `SCWindow.frame` at capture time), or a display excluding Vishot's own windows. None of these include the overlay, so the editor captures with it up. It returns a `Capture` with the frame the content had at capture time. `capture(_:)` (the ↵ path, after the overlay hides) and the editor both end in `copy(_:scale:)`: the pasteboard gets a lazy `NSPasteboardItemDataProvider`, so PNG/TIFF encoding happens only on paste. The provider must stay retained (`Capturer.provider`). `save(_:scale:to:)` writes the PNG on a background queue and falls back to the clipboard if the write fails. Both encode through `ImageEncoding`, which tags the Retina DPI. Both also add the `Watermark` at that point (on paste, or on the save queue), so it costs nothing until then.
- **Editor model (`Annotation.swift`)**: pure and tested. `Annotation` (arrow, rect, text), `EditDocument` (image, scale, annotations, crop), `EditHistory` (undo/redo of `EditSnapshot`s). All geometry is in **image space**: points from the image's top-left, y down. Screen positions are never stored.
- **Cursor (`Cursor.swift`)**: shared by the editor and Region mode, so changing it changes both. `EditCursor` is the aiming point clamped to a `bounds` rect (the image in image space, or a display in CG global space), with 6/15/48 pt tap steps for ⌥/plain/⇧ and edge jumps. `CursorGlide` gives speed and direction while keys are held. `KeyboardCursor` maps the keys (`hjkl`/arrows, `0 $ g G M`) onto an `EditCursor`. macOS repeats only the last key held, so it tracks held direction keys (key-up comes through `OverlayPanel.onKeyUp`, and `CGEventSource.keyState` catches lost key-ups) and glides on a 120 Hz timer, calling `onChange` to render. `CGRect(corners:)` and `Drag.isClick` live here too. `SelectionStyle` holds the crosshair and dim layers both draw.
- **Region mode (`Region.swift`)**: `RegionSelection` is the pure, tested part. It works like the editor's crop: `v` anchors at the cursor and `v` again finishes, a mouse drag past `Drag.isClick` draws from the press, and a click inside the finished region copies it. Corners are rounded to whole points, and an empty region is dropped. `RegionSelector` owns a `KeyboardCursor` clamped to one display (changed by `Tab` or the mouse only while idle) and turns the region into a `CaptureTarget.Kind.region(displayID:rect:)`. `Capturer` captures that display and crops it with `cropRect`, so ↵ and ⇧↵ work as in the other modes. `OverlayPanel.showRegion` draws the dim and crosshair; the outline and size label are the usual `highlight`.
- **Look**: the landing page's (`site/style.css`). `Palette` holds its colors under the CSS variable names. `Fonts` registers the site's own Silkscreen and JetBrains Mono, which `scripts/build.sh` copies from `site/fonts` into the bundle; without them (raw `swift build` binary) text falls back to the system monospaced font. Silkscreen is used only at 16 pt, where its pixels land on whole device pixels, and its text layers snap their baseline to a device pixel. Panels are square with a 2 pt edge and a hard shadow.
- **`AnnotationRenderer`**: `draw` renders annotations in image space as pixel art: arrows and rectangles are cells of `PixelArt`'s 3 pt grid (anchored at the image's top-left) with a hard one-cell shadow, and text is Silkscreen at 24 pt, whose pixels are the same cells, snapped to the grid. The default color is `purple` (`Palette.accent`). `draw` is used both on screen and by `export`, which draws into a bitmap at pixel size and crops (`pixelRect`). With no annotations, export returns the captured pixels without a redraw.
- **`Watermark`**: the "vishot.dev" credit in the landing page's look (the pixel font's small capitals on a square dark plate with a hard amber shadow, always on) in the bottom-right corner of every copied or saved image, sized in points. It is drawn through `AnnotationRenderer.imageSpaceContext`, like export, and left out when the badge and its margins would take more than half the image's width or height. It isn't shown in the editor.
- **`EditorController`** (`Editor.swift`): document, history, cursor, tool, color, and the action in progress (`idle`, `anchored` from a tool key, `dragging` with the mouse, `typing`). Tool keys anchor at the cursor and the same key, ↵, or esc finishes; a mouse drag draws from down to up. Finishing actions commit what is in progress, export, and call `onFinish`. Text typing reads `event.characters`; everything else matches key codes. `render(on:)` builds an `EditorScene` and shows the toolbar on the panel holding most of the image.
- **`EditorLayer`**: one per `OverlayPanel`, built with it and hidden until editing: the frozen image at its global rect, an annotations layer drawn through `AnnotationRenderer.draw` (sized to the visible part only), even-odd dim layers (45% outside the image, 70% outside the crop), crosshair (both from `SelectionStyle`), caret, the crop outline, and the CALayer toolbar. The crop outline is a rectangle annotation's pixel ring with its shadow, on the cells just outside the crop: accent while drawn, then white. The toolbar is the picker's HUD with the editor's keys (an `EDIT` name, two rows of entries, a status line); each entry is a layer that hit-tests points into `ToolbarItem`s. The toolbar goes below the image, else above, else inside the bottom edge.
- **Save as**: `NSSavePanel` can't show above the `.screenSaver` panels, so `OverlayController` orders them out (with `isPresentingSavePanel` keeping `windowDidResignKey` from cancelling), activates Vishot, and on cancel reshows them with the editor intact. `hide()` reactivates the app that was frontmost before.

### Coordinate spaces

`CaptureTarget.frame`/`anchor`, AX positions, and all catalog/navigation math use **CoreGraphics global space** (top-left origin of the primary display, y down). AppKit panels, `NSScreen.frame`, and `NSEvent.mouseLocation` use **Cocoa space** (bottom-left origin). Convert with `CGRect`/`CGPoint.flippedBetweenCocoaAndCG` (each its own inverse) and `NSScreen.cgFrame`, all defined in `WindowCatalog.swift`. The editor adds **image space** (points from the captured image's top-left, y down): `EditorController` converts mouse points by subtracting the image's CG origin, and `EditorLayer` maps image space into each panel's y-up layer coordinates.

### Performance

Latency is the main design constraint, and the README's "Speed notes" describe the intended trade-offs. Keep the hotkey-to-overlay path free of ScreenCaptureKit/AX calls, per-show allocations of windows, and eager image encoding. Nothing of the editor runs before ⇧↵; its layers are built with the panels, export happens only on finish, and copy stays lazy. AX element discovery runs only after `f`; window raising runs on keyboard navigation. `AccessibilityAvailability` refreshes trust on a background serial queue every 0.5 s and publishes a main-thread snapshot for picker startup and HUD updates. Setup and Settings read live permission status; `f` still live-checks trust without prompting. `DisplayCatalog` runs only on `G` and `v`.

## Agent skills

### Issue tracker

Issues live in beads (`bd` CLI, database in `.beads/`). See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), applied as beads labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
