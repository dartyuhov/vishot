# Add a built-in theme

You add a theme by defining its complete look in Swift and registering it once.
Themes reuse the existing drawing treatments. You don't need to change picker,
editor, or history drawing code.

## Define and register the theme

Use an existing definition as a starting point, without inheriting from it.

1. Copy `Sources/Vishot/PixelTheme.swift` or
   `Sources/Vishot/SmoothTheme.swift` to a new Swift file in the same directory.
2. Rename the enclosing type and set the definition's unique, stable `id` and
   display `label`. The identifier is also the existing configuration's `style`
   value, so use a lowercase identifier without spaces or TOML punctuation.
3. Set `appearances` to `.light`, `.dark`, or `.both`. The factory receives the
   effective color scheme: an unsupported request falls back to the supported
   variant without changing the user's saved Appearance preference.
4. Choose an existing `annotationID`: `.pixel` for cell-based markup or `.clean`
   for Smooth's vector markup. These stable presets include annotation fonts and
   measurements. They are separate from your theme's selection identifier.
5. Customize the complete `ThemeStyles` value returned by your factory: HUD,
   picker, selection feedback, editor controls, history, Settings, and watermark.
6. Add your definition to `ThemeCatalog.definitions`. Its order determines the
   order in Settings. Selection, labels, and configuration lookup use this list.

You don't add a case to `VisualStyle` or `ThemeID`. The named Pixel and Smooth
accessors exist for defaults and legacy compatibility, not registration.

## Reuse drawing treatments

Definitions select treatments and values rather than adding drawing algorithms.

- `OutlineTreatment` provides pixel and rounded outlines.
- `PanelStyle` provides background, border, corner, and shadow values.
- `SelectionDrawingStyle` defines the crosshair and dim treatment.
- `WatermarkStyle` provides pixel glyphs or system text with a plate.
- Saved annotation presets provide cell-based or vector markup.

Keep the watermark palette independent of light/dark interface appearance.
Changing Appearance must not recolor captured pixels or saved markup. A theme can
combine treatments, such as rounded controls with the Pixel annotation preset.

## Preserve resource and screenshot lifetimes

Factories resolve fonts and colors when the app prepares styling, outside the
hotkey path. Keep font resolution inside the factory so it runs after bundled
fonts are registered. Don't capture resolved fonts in static definition values.

Consumers receive immutable resolved styling. Active capture, history, and editor
sessions keep it until they end. An editable screenshot retains its original
annotation preset, while controls follow the current session theme. Clipboard
providers and background saves retain the originating watermark styling.

## Verify the contribution

Test the catalog resolution interface and existing compatibility behavior.

1. Add coverage for your theme's advertised variants and fallback behavior in
   `ThemeCatalogTests`. Check that its identifier parses through `AppSettings`
   and that its label matches the selectable choice.
2. Run `swift build` and `swift test`. Retain the settings, saved-markup, export,
   and delayed-output regression coverage.
3. Evaluate the signed app across picker modes, hints, history, editor controls,
   and actual pasted/saved output in each supported appearance and at 1x and 2x.

Single-appearance fixtures belong in tests; you don't need an extra shipping theme
to test fallback. New annotation presets, external theme files, and runtime theme
loading require separate design work.
