# Capture modes: Window, Element, Screen

Status: design approved in chat on 2026-10-03, pending spec review.
Follow-up (separate spec): post-capture editor (beautify + annotate), opened with an opt-in key.

## Goal

The hotkey still opens the window picker, and Return still copies instantly. From the picker you can switch with
vi-style keys to two more modes: **Element** (`v`), which picks a UI element inside a window, and **Screen** (`G`),
which picks a whole display. A HUD at the bottom of the screen always shows the current mode and its keys. The mouse
works in every mode: hover selects and click captures.

Success criteria:

- Opening the overlay is as fast as today. No AX or ScreenCaptureKit work on the hotkey path.
- In Safari, Slack, Electron apps (Obsidian), and Chromium browsers (Helium, Chrome), Element mode reaches the main
  regions (sidebar, header, main content, lists) in a few `hjkl`/`i` presses.
- Element and screen captures land on the clipboard with the same lazy, DPI-tagged provider as window captures.

## Non-goals

- The editor. `⇧Return` / `⇧click` stay unbound for now.
- Free-form drag rectangles.
- Firefox-specific handling. Firefox is untested (not installed). It gets the generic path, and fixes are follow-ups.
- Persistent settings and configurable keys.

## Modes and keys

Keys are matched by key code (`kVK_*`), as they are today. `G` means `kVK_ANSI_G` with Shift. Plain `g` is unbound.

| Key | Window (default) | Element | Screen |
|---|---|---|---|
| `hjkl` / arrows | nearest window in direction | nearest sibling element | nearest display |
| `Tab` / `⇧Tab` | cycle windows front to back | cycle siblings | cycle displays |
| `Return` / `Space` / keypad Enter | capture window | capture element | capture display |
| `v` / `V` | enter Element on the selected window | — | — |
| `i` | — | go into the selected element's children | — |
| `o` | — | go out to the parent; at top level same as `Esc` | — |
| `G` | enter Screen | enter Screen | — |
| `Esc` | cancel | back to Window | back to Window |
| `q` | cancel | cancel | cancel |

`Esc Esc` therefore always quits. Keys marked "—" are ignored.

Selection when entering a mode:

- **Window**: the frontmost app's window, as today. When returning from Element or Screen, the window that was being
  browsed, or the window containing the screen's former selection.
- **Element**: the top-level element under the mouse cursor if the cursor is inside the window, otherwise the largest
  one.
- **Screen**: the display containing the anchor of the current window or element selection.

## Mouse

Panels stop ignoring mouse events. Each panel's content view has an `NSTrackingArea` with `.mouseMoved` and
`.activeAlways`, so hover works on screens whose panel is not key.

| Mode | Hover | Click |
|---|---|---|
| Window | the frontmost window under the cursor | capture it |
| Element | the smallest element at the current level under the cursor, in the window under the cursor. Moving over another window re-roots Element mode at that window's top level | capture it |
| Screen | the display under the cursor | capture it |

Hovering over empty space keeps the current selection. Clicking empty space does nothing.

## Data model

```swift
struct CaptureTarget {
    enum Kind {
        case window(CGWindowID)
        case element(windowID: CGWindowID, rect: CGRect)
        case display(CGDirectDisplayID)
    }
    let kind: Kind
    let frame: CGRect     // CG global space
    let anchor: CGPoint   // CG global space, used by Navigator
    let label: String
}
```

- Window targets map from `WindowInfo`, whose anchor is the visible-area centroid as today. `WindowCatalog` keeps
  returning `[WindowInfo]`, because `pid` is needed for the AX lookup.
- Display targets come from `DisplayCatalog.displays()`. The frame is `NSScreen.cgFrame`, the anchor is the center,
  the label is `localizedName`, and the ID is `NSScreenNumber`.
- Element targets come from `ElementCatalog`. The frame is the AX frame clipped to the window, the anchor is the center
  of the clipped frame, and the rect is the clipped frame.

`Navigator.neighbor` works on `[CaptureTarget]` and takes and returns indices. The ranking algorithm is unchanged.

## Element mode (`ElementCatalog`)

Findings behind these rules are in "Spike findings" below.

**Permission.** On the first `v`, call `AXIsProcessTrustedWithOptions` with the prompt option. If Vishot isn't
trusted: beep, show the HUD status `Allow Vishot in System Settings → Privacy & Security → Accessibility`, and stay
in Window mode. The system prompt may take key focus, which cancels the overlay through `windowDidResignKey`. That's
acceptable. The permission is never requested at launch.

**Window lookup.** `AXUIElementCreateApplication(pid)`, then search `kAXWindowsAttribute` for the window whose
`CGWindowID` matches, using the private `_AXUIElementGetWindow` (loaded through `@_silgen_name`). If that fails, fall
back to the window whose AX frame equals the CG frame. If there's no match: beep and stay in Window mode.

**Timeout.** `AXUIElementSetMessagingTimeout(app, 0.25)` on every app element we create.

**Loading a level.** Only the children of the current element are loaded, once per `v`/`i`/`o` or window change:

1. Read `kAXChildrenAttribute`. For each child, read position, size, role, subrole, role description, and title in
   one `AXUIElementCopyMultipleAttributeValues` call.
2. Drop children that:
   - have no frame, or whose frame clipped to the window is under 8 pt on either side;
   - are window buttons (subrole `AXCloseButton`, `AXMinimizeButton`, `AXFullScreenButton`, `AXZoomButton`);
   - have subrole `AXEmptyGroup` (screen-reader-only nodes);
   - have no children and a frame within 2 pt of the parent's frame (background views).
3. **Auto-descend:** if exactly one child remains and it has children, replace the level with that child's level and
   repeat (limit of 30 steps). If the single child is a leaf, the level is that one child.
4. `i` on an element whose level comes out empty: beep and show the HUD status `nothing inside`.

The `o` key pops the stack of levels. The stack stores the parent element and the selected index for each level, so
going out restores the previous selection.

**Labels.** Role description plus the title or description, truncated to 40 characters, e.g. `toolbar — Inbox`. With
no title: role description plus size, e.g. `group 1102×883`. `AXValue` is never read, because it can be a large blob of
text.

**Enabling Electron and Chromium trees.** Done once per app process per Vishot session, the first time Element mode
touches that app:

- Always set `AXManualAccessibility = true` on the app element. Electron uses it, and other apps ignore it.
- If the window's top-level child has DOM class `BrowserRootView` (every Chromium browser), also set
  `AXEnhancedUserInterface = true` on the app element. **Ignore the return code**: Chrome returns "not implemented"
  (-25208) even though the flag works.
- After setting a flag, the app is "warming" for up to 3 s. Every 100 ms the current level reloads. If the targets
  change, the selection is kept by index where possible. The HUD shows `loading page…` until the 3 s window ends,
  which also stops the reloads. Keys keep working during warm-up, and it never blocks the main thread for more than one level load.

**Open question: Chromium flag lifetime.** In Chrome, setting `AXEnhancedUserInterface` back to false removes the web
tree immediately, and enabling it again takes about 2.1 s every time. Leaving it on may make window-manager moves of
that browser animate or slow down (AeroSpace). This is postponed. The implementation uses one constant,
`ElementCatalog.restoresEnhancedUserInterface`, defaulting to `false` (leave on until the app quits). Measure the
AeroSpace impact during manual testing.

## Capture (`Capturer`)

`capture(_ target: CaptureTarget)` replaces `capture(windowID:)`. `prefetch()` is unchanged. The shared private
`capture(filter:crop:)` runs `SCScreenshotManager.captureImage`, crops if a crop is given, and calls
`copyToPasteboard`.

- **Window**: as today.
- **Element**: the same window filter. Crop rect in pixels =
  `((rect.origin − scWindow.frame.origin) × scale, rect.size × scale)`, made integral and intersected with the image
  bounds. Use `SCWindow.frame` at capture time, not the catalog frame. An empty intersection beeps.
- **Display**: find the `SCDisplay` by `displayID`. Use
  `SCContentFilter(display:excludingApplications: [own SCRunningApplication], exceptingWindows: [])`, with the size
  from `contentRect × pointPixelScale`. `showsCursor = false`.

Errors beep and log, as today.

## Overlay and HUD

- `OverlayPanel` moves to `OverlayPanel.swift`. `OverlayController` stays in `Overlay.swift` and owns the mode, the
  current targets, the selected index, the element level stack, and key and mouse dispatch.
- Highlight is unchanged: the accent border and label. A target whose frame touches the screen edge (always true for
  displays) draws its border inset instead of outset, so the border stays visible.
- **HUD**: a rounded, semi-opaque layer group per panel, created with the panel, at the bottom center, 24 pt from the
  bottom edge. It is visible only on the panel whose screen contains the selection's anchor. It has two text lines:
  - the key line, fixed per mode:
    - `WINDOW   hjkl move · v elements · G screen · ↵ copy · esc cancel`
    - `ELEMENT  hjkl move · i in · o out · G screen · ↵ copy · esc back`
    - `SCREEN   hjkl move · ↵ copy · esc back`
  - the status line (hidden when empty), cleared on the next key press or when warm-up ends.
- All updates go through the existing `CATransaction` with actions disabled.

## Performance constraints

- `show()` does the same work as today: `WindowCatalog`, `prefetch()`, and layer updates. HUD text is set, not
  created.
- AX calls happen only after `v`, `i`, `o`, or a hover onto another window in Element mode. Each level load is a few ms
  in the apps tested.
- `DisplayCatalog` is called only on `G`.

## Files

| File | Change |
|---|---|
| `CaptureTarget.swift` | **new**: `CaptureTarget`, `DisplayCatalog` |
| `ElementCatalog.swift` | **new**: permission, window lookup, level loading, filters, Electron/Chromium enabling, warm-up |
| `ElementFilter.swift` | **new**: pure filter and auto-descend logic over a small `ElementNode` protocol, so it can be tested without AX |
| `OverlayPanel.swift` | **new**: split out of `Overlay.swift`; adds HUD layers, inset border, mouse tracking |
| `Overlay.swift` | `OverlayController` with modes, level stack, mouse handling |
| `Navigator.swift` | works on `[CaptureTarget]` and indices |
| `Capturer.swift` | `capture(_ target:)`, crop and display paths; crop math in a pure static function |
| `WindowCatalog.swift` | adds a `WindowInfo → CaptureTarget` mapping |
| `Package.swift` | adds `VishotTests` test target |
| `README.md`, `CLAUDE.md` | modes, keys, Accessibility permission, AX notes |

## Testing

**Unit tests** (`VishotTests`, XCTest, `@testable import Vishot`), covering pure logic only:

- `Navigator`: tiled neighbors beat diagonal ones, no candidate returns nil, works for display-like and element-like
  layouts.
- `ElementFilter`: each drop rule, auto-descend through single children, stopping at a leaf, the 30-step limit.
- Crop math: Retina scale, element partly outside the window (clamped), fully outside (empty).

**Manual checklist** on the installed app (`./scripts/build.sh install`):

- Window mode is unchanged. The hotkey feels as fast as before.
- `v` in Safari, Slack (a channel with messages), Obsidian, Helium, and cold Chrome: regions are reachable, `i`/`o`
  work, the HUD shows `loading page…` in cold Chrome, and the web content appears.
- The first `v` without Accessibility shows the prompt and the HUD message.
- `G`: hjkl between the two displays, capture contains no overlay.
- Hover and click in each mode, including hovering onto another window in Element mode.
- Capture pastes at on-screen size in an image editor, for window, element, and display.
- `Esc Esc` and `q` exit from every mode.
- With the Chromium flag left on, AeroSpace moves of that browser still behave (open question above).

## Spike findings (2026-10-03, throwaway probe)

| App | Tree | Enable cost | Level load |
|---|---|---|---|
| Safari | present without flags | 0 | ~0.5–3 ms |
| Slack (Electron) | present with `AXManualAccessibility` | ~0 | ~0.4–8 ms |
| Obsidian (Electron) | present | 0 | ~0.4–3 ms |
| Helium (Chromium) | already present | 0 | ~0.5–4 ms |
| Chrome, cold | web area empty until `AXEnhancedUserInterface` | ~2.1 s each enable | ~2–6 ms |
| Firefox | not tested | — | — |

- Setting `AXEnhancedUserInterface` reports -25208 on Chrome but works. Setting it on window elements reports -25205.
- Polling without the flag never builds Chrome's web tree.
- Setting the flag back to false removes the web tree immediately. Re-enabling costs ~2.1 s again.
- Electron and Chromium expose many wrapper groups. Auto-descend skipped 2–4 levels per step in practice.
- Auto-descend into a single leaf produced an empty level, which is the reason for the leaf rule above.

## Revision: faster element navigation (2026-10-03, after first manual test)

Reaching a single Slack message took `v` plus 3–4 `i` presses, and in Slack's channel view it was impossible:
the message list (`AXList`, class `sr-only`) reports a 1×1 frame, so the size filter dropped it with every
message inside. Changes, chosen in chat:

- **Hoisting.** A tiny or frameless node with children passes its filtered children up into the level (up to 3
  nested hoists) instead of being dropped.
- **Empty groups.** Untitled, childless `AXGroup` nodes are dropped (e.g. Slack's 409×1089 empty banner group).
- **Dominance.** Besides the single-child rule, a node covering ≥ 80% of the level's root is replaced in place by
  its children. A lone child with the root's own frame is not a level (`i` on it reports `nothing inside`).
  Slack's first level becomes: toolbars, tabs, message area, composer; `i` on the message area lists the messages.
- **Hover goes deep.** In Element mode, hover selects the deepest element under the cursor and builds the whole
  level stack, so `o` widens and `hjkl` moves among its siblings. Levels are cached per window for hover.
- **Hint labels.** `f` (Window or Element mode) labels every element up to 3 levels below the current root,
  skipping containers ≥ 40% of it, capped at 300. Labels are home-row-first letters, all the same length; typing a
  full label selects that element. `⌫` undoes a letter, `Esc` leaves hint mode. Measured: Slack 96 labels in
  17 ms, Helium (Gmail) 69 labels in 84 ms.

The separate "lists open to their items" rule was dropped: hoisting plus dominance covered the tested apps.
