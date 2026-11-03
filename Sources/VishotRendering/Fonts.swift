import AppKit
import CoreText

/// The landing page's fonts, copied into the app from site/fonts by scripts/build.sh: Silkscreen, a
/// pixel font, for short labels, and JetBrains Mono for keys and text. Without them, as in the raw
/// `swift build` binary, both fall back to the system's monospaced font.
public enum Fonts {
    /// Registers fonts in `<resourceDirectory>/Fonts` for this process. The executable supplies
    /// its installation's Resources directory. Call before resolving annotation or GUI styles.
    /// Returns whether all bundled families are available from this directory in this process.
    @discardableResult
    public static func register(resourceDirectory: URL) -> Bool {
        let directory = resourceDirectory.appendingPathComponent("Fonts", isDirectory: true)
        let names = ["silkscreen-latin-400-normal", "silkscreen-latin-700-normal",
                     "jetbrains-mono-latin-400-normal", "jetbrains-mono-latin-700-normal"]
        var registered = true
        for name in names {
            let url = directory.appendingPathComponent(name + ".woff2")
            // Repeat calls are normal in module tests and long-lived consumers. Only accept an
            // existing registration for this exact file, not a same-named system font.
            if CTFontManagerGetScopeForURL(url as CFURL) == .process { continue }
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) { registered = false }
        }
        return registered && NSFont(name: "Silkscreen-Regular", size: 24) != nil
            && NSFont(name: "JetBrainsMono-Regular", size: 16) != nil
            && NSFont(name: "JetBrainsMono-Bold", size: 16) != nil
    }

    /// Silkscreen has 8 pixels to the em, so 16 pt puts each of its pixels on whole device pixels on
    /// both Retina and 1× screens.
    public static func pixel(_ size: CGFloat = 16) -> NSFont {
        NSFont(name: "Silkscreen-Regular", size: size) ?? .monospacedSystemFont(ofSize: size * 0.75, weight: .bold)
    }

    public static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
