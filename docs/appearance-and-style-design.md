# Independent appearance and style

This proposed design replaces the unified Pixel/Clean theme choice with two
independent settings. It describes the next change to the visual-themes branch;
it does not describe behavior already delivered by that branch.

## Settings and visual behavior

Settings exposes exactly two selectors:

```text
Appearance: System / Light / Dark
Style:      Pixel / Smooth
```

Appearance determines the interface color scheme. Style determines typography,
shape geometry, borders, shadows, and screenshot markup rendering. Both Pixel
and Smooth support light and dark interface colors. System resolves to the
macOS appearance without changing the selected style.

The interface includes app-owned Settings content, picker modes, hints, HUDs,
region feedback, history, and editor controls. Native controls follow the
resolved appearance where AppKit supports it. Brand assets stay unchanged.

Captured image pixels and annotation color choices do not change with interface
appearance. Pixel and Smooth determine annotation rendering and watermark
treatment. Watermarks retain a predictable, readable output treatment rather
than inheriting interface light/dark colors. There is no separate screenshot
style selector.

## Defaults and configuration compatibility

The proposed fresh-install defaults are System appearance and Pixel style.
Configuration uses root-level string values:

```toml
appearance = "system"
style = "pixel"
```

Appearance accepts `system`, `light`, or `dark`. Style accepts `pixel` or
`smooth`. Invalid values retain the existing last-good configuration and error
reporting behavior. Settings edits preserve comments and unrelated values.

The current branch writes `theme = "pixel"` or `theme = "clean"`. For
compatibility, legacy Pixel maps to Pixel and legacy Clean maps to Smooth.
When only the legacy setting exists, appearance resolves to Dark to preserve
the existing dark interface. An explicit appearance overrides that fallback;
an explicit style takes precedence over the legacy theme. Validate any supplied
legacy value rather than silently accepting invalid configuration.

When Settings changes either selector in a legacy file, conservatively migrate
the legacy assignment to explicit appearance and style values without changing
the other effective preference. Do not rewrite files merely on launch.

## Resolution and session consistency

Keep color-scheme resolution independent from style identity. Centralized
definitions combine the resolved light/dark palette with Pixel/Smooth component
treatments; consumers receive immutable resolved styles.

Resolve fonts, colors, and reusable panel styling outside the hotkey path.
Explicit changes apply when idle. While System is selected, macOS appearance
changes follow the same path. An active capture, history, or editor session
keeps its resolved appearance and style until it ends. Settings explains pending
changes, including a pending system appearance change.

History-to-editor transitions and Save As cancellation continue the same session.
Clipboard providers and background saves retain immutable output preferences
from their originating request.

## Existing screenshots

An editable screenshot retains its saved annotation style, including newly
added markup and undo/redo. Surrounding editor controls use the current session
appearance and style. Stored preview pixels remain unchanged.

Legacy history with no annotation style remains Pixel. Existing `clean` style
metadata remains readable as Smooth. Keep persisted legacy history identifiers
compatible; the user-facing rename does not require a bulk history rewrite.
Unsupported metadata continues through the existing unsupported-entry path.

## Verification

Extend existing configuration, session-deferral, rendering, history, and output
tests at their observable boundaries. Cover all four style/color combinations,
System resolution and changes, legacy configuration migration, last-good
validation, preserved saved styles, and delayed output stability.

Run Swift build and tests. Verify the signed installed app at actual 1x and 2x
across Settings, capture modes, hints, history states, editor tools, crop, and
actual pasted/saved output. Record unavailable display or desktop coverage
explicitly.

## Next steps

Review this written design, especially the proposed defaults and legacy
configuration behavior. After approval, prepare and review an implementation
plan before changing application code.
