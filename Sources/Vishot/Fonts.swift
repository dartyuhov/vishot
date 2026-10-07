import AppKit
import CoreText

/// The landing page's fonts, copied into the app from site/fonts by scripts/build.sh: Silkscreen, a
/// pixel font, for short labels, and JetBrains Mono for keys and text. Without them, as in the raw
/// `swift build` binary, both fall back to the system's monospaced font.
enum Fonts {
    /// Registers the bundled fonts for this process. Call before anything asks for a font.
    static func register() {
        for url in Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: "Fonts") ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Silkscreen has 8 pixels to the em, so 16 pt puts each of its pixels on whole device pixels on
    /// both Retina and 1× screens.
    static func pixel(_ size: CGFloat = 16) -> NSFont {
        NSFont(name: "Silkscreen-Regular", size: size) ?? .monospacedSystemFont(ofSize: size * 0.75, weight: .bold)
    }

    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
