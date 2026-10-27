# Add a built-in theme

You add a theme by defining its complete look in Swift and registering its
selectable identity in shared configuration and its GUI definition in the app.
Themes reuse the existing drawing treatments. You don't need to change picker,
editor, or history drawing code.

## Define and register the theme

Use an existing definition as a starting point, without inheriting from it.

1. Copy `Sources/Vishot/PixelTheme.swift` or
   `Sources/Vishot/SmoothTheme.swift` to a new Swift file in the same directory.
2. Add a case to `VisualStyle` in
   `Sources/VishotConfiguration/Preferences.swift`, with its label, stable raw
   identifier, and `annotationID` mapping. Choose `.pixel` for cell-based markup
   or `.clean` for Smooth's vector markup. This is the authoritative selectable
   treatment mapping for both app and CLI. `VisualStyle.allCases` determines
   Settings order and the accepted configuration choices.
3. Rename the enclosing GUI type and set the definition's unique, stable `id`
   and display `label`. The identifier is also the configuration's `style` value,
   so use a lowercase identifier without spaces or TOML punctuation.
4. Set `appearances` to `.light`, `.dark`, or `.both`. The factory receives the
   effective color scheme: an unsupported request falls back to the supported
   variant without changing the user's saved Appearance preference.
5. Derive the definition's `annotationID` from your shared preference case, as
   `VisualStyle.smooth.annotationID` does in `SmoothTheme`. The stable preset
   includes annotation fonts and measurements and is separate from the theme's
   selection identifier. GUI factories remain independently extensible; custom
   definitions can explicitly reuse a saved treatment without a selectable case.
6. Customize the complete `ThemeStyles` value returned by your factory: HUD,
   picker, selection feedback, editor controls, history, Settings, and watermark.
7. Add your definition to `ThemeCatalog.definitions` in
   `Sources/Vishot/Theme.swift`. `ThemeCatalog.definition(for:)` connects the
   shared preference's identifier to app-owned GUI styling.

Reuse a `ThemeID` from `VishotRendering`; adding a selectable style does not
require a new persisted treatment. Keep legacy `pixel`/`clean` history values
and their compatibility mapping stable.

## Reuse drawing treatments

Definitions select treatments and values rather than adding drawing algorithms.

- `OutlineTreatment` provides pixel and rounded outlines.
- `PanelStyle` provides background, border, corner, and shadow values.
- `SelectionDrawingStyle` defines the crosshair and dim treatment.
- `WatermarkStyle` provides pixel glyphs or system text with a plate.
- `VishotRendering.AnnotationCatalog` provides cell-based or vector markup,
  shared by the editor and CLI. Keep treatment construction out of GUI factories.

Keep the watermark palette independent of light/dark interface appearance.
Changing Appearance must not recolor captured pixels or saved markup. A theme can
combine treatments, such as rounded controls with the Pixel annotation preset.

## Preserve resource and screenshot lifetimes

Factories resolve fonts and colors when the app prepares styling, outside the
hotkey path. Keep font resolution inside the factory so it runs after bundled
fonts are registered. Don't capture resolved fonts in static definition values.
The app supplies its bundle resource directory; the helper supplies the resolved
containing installation's resource directory. `Fonts.register` runs before
`AnnotationCatalog` resolves treatment values. The helper rejects unavailable
bundled fonts instead of silently publishing fallback text.

Consumers receive immutable resolved styling. Active capture, history, and editor
sessions keep it until they end. An editable screenshot retains its original
annotation preset, while controls follow the current session theme. Clipboard
providers and background saves retain the originating watermark styling.

## Verify the contribution

Test the catalog resolution interface and existing compatibility behavior.

1. Add coverage for your theme's advertised variants and fallback behavior in
   `VishotTests/ThemeCatalogTests`. Check shared identity, mapping, and parsing in
   `VishotConfigurationTests`, and drawing through `VishotRenderingTests`.
   CLI integration belongs in `VishotCLIExecutionTests`, without a GUI import.
2. Run `swift build --force-resolved-versions` and
   `swift test --force-resolved-versions`. Retain the settings, saved-markup, export,
   and delayed-output regression coverage.
3. Evaluate the signed app across picker modes, hints, history, editor controls,
   and actual pasted/saved output in each supported appearance and at 1x and 2x.

Single-appearance fixtures belong in tests; you don't need an extra shipping theme
to test fallback. New annotation presets, external theme files, and runtime theme
loading require separate design work.
