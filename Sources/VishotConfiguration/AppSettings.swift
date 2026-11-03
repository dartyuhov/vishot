import Foundation
import TOMLKit
import VishotRendering

public struct SettingsError: LocalizedError {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A configuration value with no file watching, writing, hotkey, or session ownership.
public struct AppSettings: Equatable {
    public var appearance: AppearancePreference
    public var style: VisualStyle
    // History identifiers remain stable; application preferences use appearance/style.
    public var theme: ThemeID {
        get { style.annotationID }
        set { style = VisualStyle(annotationID: newValue) }
    }
    public var watermark: Bool
    public var shortcut: CaptureShortcut
    public var historyRetention: HistoryRetention
    public var historyShortcut: CaptureShortcut?

    public init(appearance: AppearancePreference = .system, style: VisualStyle = .pixel,
                watermark: Bool = true, shortcut: CaptureShortcut = .defaults,
                historyRetention: HistoryRetention = .sevenDays, historyShortcut: CaptureShortcut? = nil) {
        self.appearance = appearance
        self.style = style
        self.watermark = watermark
        self.shortcut = shortcut
        self.historyRetention = historyRetention
        self.historyShortcut = historyShortcut
    }

    public static let defaults = AppSettings()
    public static let defaultSource = """
    # Interface colors: system, light, or dark.
    appearance = "system"
    # Interface and markup rendering: \(VisualStyle.allCases.map(\.rawValue).joined(separator: " or ")).
    style = "pixel"

    # Keep this on to help others discover Vishot.
    watermark = true

    # Physical key positions, independent of your keyboard layout.
    [shortcut]
    key = "S"
    modifiers = ["command", "shift"]

    [history]
    # 0 disables new entries; existing entries still expire.
    retention_days = 7

    # Assign an optional History shortcut in Settings.
    shortcut = false

    """

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/vishot/config.toml")

    /// Missing configuration uses defaults without creating a file or its parent directory.
    public static func read(url: URL = defaultURL) throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// Validate the whole configuration before selecting a local rendering preference.
    public static func annotationStyleSnapshot(url: URL = defaultURL) throws -> VisualStyle {
        do { return try read(url: url).style }
        catch {
            throw SettingsError(message: "Could not resolve the selected annotation style from \(url.path): \(error.localizedDescription)")
        }
    }

    public static func parse(_ source: String) throws -> AppSettings {
        let table = try TOMLTable(string: source)
        var settings = defaults
        if let value = table["theme"] {
            guard let name = value.string, let theme = ThemeID(rawValue: name) else {
                throw SettingsError(message: "theme must be \"pixel\" or \"clean\".")
            }
            settings.theme = theme
            settings.appearance = .dark
        }
        if let value = table["appearance"] {
            guard let name = value.string, let appearance = AppearancePreference(rawValue: name) else {
                throw SettingsError(message: "appearance must be \"system\", \"light\", or \"dark\".")
            }
            settings.appearance = appearance
        }
        if let value = table["style"] {
            guard let name = value.string, let style = VisualStyle(rawValue: name) else {
                let choices = VisualStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                throw SettingsError(message: "style must be \(choices).")
            }
            settings.style = style
        }
        if let value = table["watermark"] {
            guard let flag = value.bool else { throw SettingsError(message: "watermark must be true or false.") }
            settings.watermark = flag
        }
        if let value = table["shortcut"] {
            guard let shortcut = value.table else { throw SettingsError(message: "shortcut must be a TOML table.") }
            if let value = shortcut["key"] {
                guard let key = value.string else { throw SettingsError(message: "shortcut.key must be a physical key name.") }
                settings.shortcut.key = key
            }
            if let value = shortcut["modifiers"] {
                guard let array = value.array else { throw SettingsError(message: "shortcut.modifiers must be an array of strings.") }
                var names: [String] = []
                for value in array {
                    guard let name = value.string else { throw SettingsError(message: "Every shortcut modifier must be a string.") }
                    names.append(name)
                }
                settings.shortcut.modifiers = names
            }
        }
        settings.shortcut = try settings.shortcut.validated()
        if let value = table["history"] {
            guard let history = value.table else { throw SettingsError(message: "history must be a TOML table.") }
            if let value = history["retention_days"] {
                guard let days = value.int, let retention = HistoryRetention(rawValue: days) else {
                    throw SettingsError(message: "history.retention_days must be 0, 1, 3, 7, or 30.")
                }
                settings.historyRetention = retention
            }
            if let value = history["shortcut"] {
                if value.bool == false { settings.historyShortcut = nil }
                else {
                guard let shortcut = value.table else { throw SettingsError(message: "history.shortcut must be a TOML table.") }
                var assigned = CaptureShortcut(key: "H", modifiers: ["command", "shift"])
                if let value = shortcut["key"] {
                    guard let key = value.string else { throw SettingsError(message: "history.shortcut.key must be a physical key name.") }
                    assigned.key = key
                }
                if let value = shortcut["modifiers"] {
                    guard let array = value.array else { throw SettingsError(message: "history.shortcut.modifiers must be an array.") }
                    assigned.modifiers = try array.map {
                        guard let name = $0.string else { throw SettingsError(message: "Every History shortcut modifier must be a string.") }
                        return name
                    }
                }
                settings.historyShortcut = try assigned.validated()
                }
            }
        }
        guard settings.shortcut != settings.historyShortcut else { throw SettingsError(message: "Capture and History shortcuts must be different.") }
        return settings
    }
}
