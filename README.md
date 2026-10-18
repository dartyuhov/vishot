<p align="center">
  <a href="https://vishot.dev/">
    <img src="Resources/logo/vishot-mark.svg" alt="Vishot app logo" width="128">
  </a>
</p>

# Vishot

[![App tests](https://github.com/dartyuhov/vishot/actions/workflows/app.yml/badge.svg?branch=main)](https://github.com/dartyuhov/vishot/actions/workflows/app.yml)
[![Site tests](https://github.com/dartyuhov/vishot/actions/workflows/site.yml/badge.svg?branch=main)](https://github.com/dartyuhov/vishot/actions/workflows/site.yml)
[![DMG packaging](https://github.com/dartyuhov/vishot/actions/workflows/package-check.yml/badge.svg?branch=main)](https://github.com/dartyuhov/vishot/actions/workflows/package-check.yml)
[![Release tooling](https://github.com/dartyuhov/vishot/actions/workflows/release-tooling.yml/badge.svg?branch=main)](https://github.com/dartyuhov/vishot/actions/workflows/release-tooling.yml)

**[Website](https://vishot.dev/)** ·
**[Downloads](https://github.com/dartyuhov/vishot/releases/latest)** ·
**[Homebrew tap](https://github.com/dartyuhov/homebrew-tap)**

Keyboard-first screenshots for macOS. Press a hotkey, pick a window or a whole display with `hjkl` (or a UI element by its label, or any region), and the image is on the clipboard. Or press `⇧Return` to add arrows, boxes and labels first.

## Install

Vishot requires **macOS 14 Sonoma or later**. Install with Homebrew:

```sh
brew install --cask dartyuhov/tap/vishot
```

Homebrew selects Apple Silicon or Intel automatically, verifies the DMG checksum,
and installs Vishot into Applications. Open **Vishot** from **Applications**,
then follow the launch approval and permission instructions below.

To update an existing Homebrew installation, quit Vishot and run:

```sh
brew update
brew upgrade --cask dartyuhov/tap/vishot
```

The [public cask](https://github.com/dartyuhov/homebrew-tap/blob/main/Casks/vishot.rb)
is generated from the published release. Broader first-install and upgrade
permission verification remains recorded in the
[installation verification record](docs/installation-verification.md).

### Choose a download

For a manual installation, download the matching DMG from the
[latest Vishot release](https://github.com/dartyuhov/vishot/releases/latest).
Skip drafts, prereleases, and releases missing either processor's DMG. Both DMGs
must have matching version numbers and their accompanying `.sha256` and `.json`
files. Don't construct an asset URL or assume that a draft is installable.

Open **Apple menu → About This Mac** to identify your processor:

| Your Mac | Download asset (`<version>` is the release number) |
|---|---|
| **Chip** shows an Apple M-series name (Apple Silicon) | `Vishot-<version>-arm64.dmg` |
| **Processor** shows an Intel name | `Vishot-<version>-x86_64.dmg` |

### Install and open

When you have the matching DMG, install the app in Applications:

1. Open the downloaded `.dmg` in Finder.
2. Drag **Vishot.app** onto the **Applications** shortcut in the disk image.
3. Wait for copying to finish, then eject the **Vishot** disk image in Finder.
4. Open **Vishot** from **Applications**, rather than from the disk image.
   Vishot runs in the menu bar; it doesn't open a normal main window or appear
   in the Dock.
5. If macOS blocks launch, after trying to open the installed app, open
   **System Settings → Privacy & Security**, find the message about Vishot,
   and choose **Open Anyway**. Confirm **Open** and authenticate if asked.
   The packages are ad-hoc signed, not Developer ID signed or
   notarized by Apple. This approval applies to Vishot individually; it
   doesn't require changing global security settings or running Terminal
   commands.

### Permissions and your first screenshot

Vishot requests Screen Recording at launch if access isn't already granted.
Accessibility is optional and enables element hints and bringing selected
windows forward. To take your first screenshot:

1. Allow Vishot in **System Settings → Privacy & Security → Screen Recording**
   (called **Screen & System Audio Recording** on newer macOS versions).
   If macOS asks you to quit and reopen Vishot, follow that prompt and reopen
   the installed app from **Applications**. Restart requirements for the
   quarantined release package have not yet been observed; Vishot doesn't
   restart itself after a permission change.
2. Put a window you want to capture in view. Press `⇧⌘S` (Shift-Command-S),
   the default capture shortcut, or choose **Capture Window** from Vishot's
   menu-bar menu. If you've changed the shortcut, the menu shows your active
   one, and **Settings…** lets you change it.
3. Select a target with `h` `j` `k` `l`, the arrow keys, or `Tab`. Press `Return`
   to copy it. You can also use `G` for a display or `v` for a region; see
   [Usage](#usage) below.
4. Switch to an app that accepts pasted images, such as a Notes note, and
   press `⌘V`. Confirm the screenshot appears.
5. To try annotations, capture again and press `⇧Return` or `e` instead of
   `Return`. Press `a` for an arrow or `r` for a rectangle, move with the arrow
   keys, and press `Return` to finish the shape. Press `y` to copy and close,
   then paste again to check the annotation.
6. To save a file, open the editor again and press `⌘S` to choose a location
   in **Save As**. Open the saved PNG to check it. In the editor, `s` saves to
   your screenshot folder and `S` saves and copies.

For optional element hints, press `f` in the picker. Vishot requests
Accessibility the first time you do this in a session. Enable Vishot in
**System Settings → Privacy & Security → Accessibility**, then open the picker
and try `f` again. Follow any macOS quit-and-reopen prompt. Without this access,
you can still use basic capture, but hints and automatic window raising aren't
available; bring the desired window forward yourself before capturing it.

### Update

There is no automatic in-app updater. For a Homebrew installation, once the
public tap is available, quit Vishot and run:

```sh
brew update
brew upgrade --cask dartyuhov/tap/vishot
```

Reopen Vishot and check the permissions and capture behavior described below.
The tap advances automatically only after a complete public regular release
passes validation; a tap-update failure can temporarily leave the prior cask
available while direct downloads remain independent.

For a direct DMG installation, use manual replacement with the same processor
choice as above:

1. Download the new DMG, then choose **Quit Vishot** from the menu-bar menu.
2. Open the new DMG and drag **Vishot.app** to **Applications**. Choose
   **Replace** when Finder asks about the existing copy. If your older copy is
   in a different folder, replace that copy rather than keeping two versions.
3. Eject the disk image and open the installed **Vishot** again.
4. If blocked, follow the per-app **Open Anyway** steps above. Check Screen
   Recording and, if you use it, Accessibility. Follow any macOS prompt to
   quit and reopen the app, then repeat capture, annotation, paste, and save.

Permission retention and exact restart behavior across ad-hoc-signed updates
are **not yet verified**. Don't assume an older approval carries over to a new
build. The verification record must resolve these checks before the public
installation flow is advertised.

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

For local development, build with Xcode and Swift 6 or later:

```sh
./scripts/build.sh           # build/Vishot.app
./scripts/build.sh install   # copy to ~/Applications and relaunch
swift test                   # unit tests for navigation, element filtering, crop math, region selection, and the editor model
```

Local builds default to your `Apple Development` certificate; override it with
`VISHOT_SIGN_IDENTITY`. A stable development identity is intended to retain
permission identity across rebuilds, but it doesn't establish permission
retention for the ad-hoc-signed distribution packages. See
[native installer packaging](docs/packaging.md) for package validation commands.

## Settings

Open **Settings…** from the menu bar to record a global capture shortcut,
toggle the watermark, or open the configuration file. The watermark defaults
to on; keeping it on helps others discover Vishot.

Settings and external file edits share `~/.config/vishot/config.toml`:

```toml
watermark = true

[shortcut]
key = "S"
modifiers = ["command", "shift"]
```

Shortcuts use physical key positions and require `command` or `control`.
Optional modifiers are `option` and `shift`. Supported keys include uppercase
letters, digits, `F1`–`F12`, and names such as `Space`, `Return`, `Tab`,
`Left`, `Right`, `Up`, `Down`, and `Minus`.

File changes reload automatically and apply after the current picker/editor
session ends. Invalid edits or unavailable shortcuts keep the working settings;
**Settings… — Configuration Error** shows how to fix them. A broken file at
startup uses defaults without overwriting it. Missing fields use defaults.

Window edits preserve comments and unrelated content. For layouts that cannot
be edited safely, such as modifier arrays containing comments, edit the file
directly. Symlinked dotfiles are supported. Output keeps the watermark choice
from copy/save time, including images encoded later when pasted.

## Speed notes

- Windows are listed with `CGWindowList` (~1 ms) rather than Accessibility or ScreenCaptureKit.
- Overlay panels are created once per screen and reused; moving the selection only moves a layer.
- `SCShareableContent` is fetched while you choose, then a single-window or single-display capture runs after the overlay closes.
- Accessibility is only touched after `f`. The walk skips everything inside elements too small to label (~20–30 ms for Slack or a browser).
- The clipboard holds a lazy provider; PNG/TIFF encoding happens only when something pastes.
- Region mode reads the displays only on `v`, and captures only the display holding the region.
- The editor costs nothing until `⇧Return`: its layers are built with the panels, and the export is drawn only when you finish.
