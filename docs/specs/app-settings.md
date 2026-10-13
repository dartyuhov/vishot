# App settings

This confirmed design defines persistent settings for Vishot. The associated
issue is `vishot-997`.

## Scope

The first version provides a native macOS Settings window and a shared,
hand-editable configuration file. It includes:

- A configurable global capture shortcut.
- A watermark toggle.
- The configuration path, with actions to open the file and reveal it in Finder.
- Configuration and shortcut-registration errors.

Internal key remapping, save-folder settings, editor defaults, themes, and a
user-selectable configuration location are outside this version.

## Configuration

The single source of truth is `~/.config/vishot/config.toml`. The Settings
window reads and edits that file. Use a compatible, maintained full TOML
parser dependency; verify its license and compatibility before selecting it.
Do not assume a parser's serializer preserves comments or formatting.

The schema uses physical key names and explicit modifiers:

```toml
# Keep this on to help others discover Vishot.
watermark = true

[shortcut]
key = "S"
modifiers = ["command", "shift"]
```

The default shortcut remains Shift+Command+S. Require Command or Control,
optionally combined with Shift and Option, and a supported non-modifier key.
Key names identify physical keyboard positions, independent of the active
keyboard layout. The menu shortcut display must reflect the active shortcut.

Settings-window writes preserve comments, unrelated content, and formatting
outside the edited values. Use atomic writes and re-read the current file
before editing to avoid replacing external changes with a stale UI snapshot.
An invalid file must be corrected before the window writes changes. If a valid
TOML representation cannot be safely edited without losing content, show a
clear error rather than silently regenerating the file.

## Applying changes

Watch for external saves, including atomic replacement of the file. Parse and
validate the complete configuration. Register a changed shortcut successfully
before retiring the working shortcut. A rejected change leaves all active
settings unchanged and surfaces an error.

Accepted changes activate between capture/editor sessions. Keep file access,
parsing, and settings-window creation off the hotkey-to-overlay path. The
active session uses a stable settings snapshot.

At startup, an invalid configuration uses built-in defaults and reports the
error without overwriting the file. There is no persistent last-working
backup. If the shortcut cannot be registered, capture remains available from
the menu bar.

## Watermark

The watermark defaults to enabled for both existing and new users. Show the
friendly explanation, "Keep this on to help others discover Vishot." Users
can disable it directly, without an extra confirmation.

Snapshot the watermark preference when copying or saving. Lazy clipboard
encoding and background saving use that snapshot, so later settings changes
do not alter previously copied images. Preserve the existing small-image
omission behavior when the watermark is enabled.

## Edge-case defaults

The following defaults complete the configuration behavior:

- Missing supported fields use built-in defaults; invalid supplied values
  reject the configuration.
- An absent file is created with commented defaults. If creation fails, use
  defaults and report the error.
- Support symlinked dotfiles. Settings-window writes preserve the symlink and
  update its target; reload observes target changes as well as link changes.
- Show errors in Settings and a visible menu-bar menu indicator. Distinguish
  configured values from still-active values after a rejected edit.
- Use native controls, a keyboard shortcut recorder, and normal keyboard
  navigation in the Settings window.

## Acceptance checks

Verification must cover behavior beyond the configuration model:

- Load defaults and a valid TOML file; reject malformed TOML, invalid types,
  unsupported keys, and invalid modifier combinations without partial apply.
- Preserve comments and unrelated content during window edits; detect stale
  edits and handle atomic saves and symlink targets.
- Change the registered shortcut without losing the old one on failure.
- Reflect the active shortcut in the menu and work on non-Latin layouts.
- Defer accepted changes until an active capture/editor session ends.
- Disable watermarking on clipboard PNG/TIFF and saved PNG output while
  retaining lazy encoding and the copy/save-time settings snapshot.
- Start with a broken or unwritable config and retain menu access to capture
  and Settings.

Use pure-logic tests for parsing, validation, source-preserving edits, and
settings transitions. Check native UI, hotkey registration, file watching,
and capture output with the signed installed app.
