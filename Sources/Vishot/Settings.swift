import AppKit
import Carbon.HIToolbox
import TOMLKit

struct SettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CaptureShortcut: Equatable {
    var key: String
    var modifiers: [String]

    static let defaults = CaptureShortcut(key: "S", modifiers: ["command", "shift"])
    static let modifierNames = ["command", "control", "option", "shift"]
    static let keys: [(String, Int)] = [
        ("A", kVK_ANSI_A), ("B", kVK_ANSI_B), ("C", kVK_ANSI_C), ("D", kVK_ANSI_D),
        ("E", kVK_ANSI_E), ("F", kVK_ANSI_F), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H),
        ("I", kVK_ANSI_I), ("J", kVK_ANSI_J), ("K", kVK_ANSI_K), ("L", kVK_ANSI_L),
        ("M", kVK_ANSI_M), ("N", kVK_ANSI_N), ("O", kVK_ANSI_O), ("P", kVK_ANSI_P),
        ("Q", kVK_ANSI_Q), ("R", kVK_ANSI_R), ("S", kVK_ANSI_S), ("T", kVK_ANSI_T),
        ("U", kVK_ANSI_U), ("V", kVK_ANSI_V), ("W", kVK_ANSI_W), ("X", kVK_ANSI_X),
        ("Y", kVK_ANSI_Y), ("Z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
        ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
        ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ("Minus", kVK_ANSI_Minus), ("Equal", kVK_ANSI_Equal),
        ("LeftBracket", kVK_ANSI_LeftBracket), ("RightBracket", kVK_ANSI_RightBracket),
        ("Semicolon", kVK_ANSI_Semicolon), ("Quote", kVK_ANSI_Quote),
        ("Comma", kVK_ANSI_Comma), ("Period", kVK_ANSI_Period),
        ("Slash", kVK_ANSI_Slash), ("Backslash", kVK_ANSI_Backslash), ("Grave", kVK_ANSI_Grave),
        ("Space", kVK_Space), ("Return", kVK_Return), ("Tab", kVK_Tab),
        ("Delete", kVK_Delete), ("Escape", kVK_Escape),
        ("Left", kVK_LeftArrow), ("Right", kVK_RightArrow),
        ("Up", kVK_UpArrow), ("Down", kVK_DownArrow),
        ("Home", kVK_Home), ("End", kVK_End), ("PageUp", kVK_PageUp), ("PageDown", kVK_PageDown),
        ("ForwardDelete", kVK_ForwardDelete),
        ("F1", kVK_F1), ("F2", kVK_F2), ("F3", kVK_F3), ("F4", kVK_F4),
        ("F5", kVK_F5), ("F6", kVK_F6), ("F7", kVK_F7), ("F8", kVK_F8),
        ("F9", kVK_F9), ("F10", kVK_F10), ("F11", kVK_F11), ("F12", kVK_F12),
    ]

    var keyCode: Int { Self.keys.first { $0.0 == key }!.1 }
    var carbonModifiers: Int {
        modifiers.reduce(0) { $0 | ["command": cmdKey, "control": controlKey, "option": optionKey, "shift": shiftKey][$1]! }
    }
    var display: String {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    func validated() throws -> CaptureShortcut {
        guard Self.keys.contains(where: { $0.0 == key }) else {
            throw SettingsError(message: "Unsupported physical shortcut key: \(key).")
        }
        guard Set(modifiers).count == modifiers.count,
              modifiers.allSatisfy(Self.modifierNames.contains),
              modifiers.contains("command") || modifiers.contains("control") else {
            throw SettingsError(message: "Shortcut modifiers must include command or control; allowed: command, control, option, shift (no duplicates).")
        }
        return CaptureShortcut(key: key, modifiers: Self.modifierNames.filter(modifiers.contains))
    }
}

struct AppSettings: Equatable {
    var watermark = true
    var shortcut = CaptureShortcut.defaults
    static let defaults = AppSettings()
    static let defaultSource = """
    # Keep this on to help others discover Vishot.
    watermark = true

    # Physical key positions, independent of your keyboard layout.
    [shortcut]
    key = "S"
    modifiers = ["command", "shift"]

    """

    static func parse(_ source: String) throws -> AppSettings {
        let table = try TOMLTable(string: source)
        var settings = defaults
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
        return settings
    }

    /// Full TOML is accepted for reading. Editing is deliberately conservative:
    /// unsupported source layouts are left untouched rather than reformatted.
    static func edit(_ source: String, watermark: Bool? = nil, shortcut: CaptureShortcut? = nil) throws -> String {
        let current = try parse(source)
        var expected = current
        if let watermark { expected.watermark = watermark }
        if let shortcut { expected.shortcut = try shortcut.validated() }
        var result = source
        let updates: [(String, String, Bool)] = [
            ("watermark", expected.watermark ? "true" : "false", expected.watermark != current.watermark),
            ("shortcut.key", "\"\(expected.shortcut.key)\"", expected.shortcut.key != current.shortcut.key),
            ("shortcut.modifiers", "[" + expected.shortcut.modifiers.map { "\"\($0)\"" }.joined(separator: ", ") + "]", expected.shortcut.modifiers != current.shortcut.modifiers),
        ]
        for (path, value, changed) in updates where changed {
            let ranges = try editableRanges(in: result)
            if let range = ranges[path] {
                // Replacing an array containing comments would erase user notes.
                guard !result[range].contains("#"), !result[range].contains("\n") else {
                    throw SettingsError(message: "Edit \(path) in the file: this value's comments or multiline formatting cannot be preserved by Settings.")
                }
                result.replaceSubrange(range, with: value)
            } else {
                let table = try TOMLTable(string: result)
                let exists = path == "watermark" ? table["watermark"] != nil : table["shortcut"]?.table?[String(path.dropFirst(9))] != nil
                guard !exists else { throw SettingsError(message: "Edit \(path) in the file: its TOML layout cannot be safely updated by Settings.") }
                // Root values must precede tables. A missing shortcut table can
                // be introduced using dotted keys before the first table too.
                if path.hasPrefix("shortcut."), table["shortcut"] != nil {
                    let pattern = #"(?m)^\[shortcut\][ \t]*(?:#[^\n]*)?(?:\r?\n|$)"#
                    guard let header = result.range(of: pattern, options: .regularExpression) else {
                        throw SettingsError(message: "Edit \(path) in the file: its table layout cannot be safely updated by Settings.")
                    }
                    let newline = result[header].hasSuffix("\n") ? "" : "\n"
                    result.insert(contentsOf: newline + "\(path.dropFirst(9)) = \(value)\n", at: header.upperBound)
                } else if path.hasPrefix("shortcut.") {
                    result += (result.hasSuffix("\n") || result.isEmpty ? "" : "\n") + "[shortcut]\n\(path.dropFirst(9)) = \(value)\n"
                } else { result = "\(path) = \(value)\n" + result }
            }
        }
        guard try parse(result) == expected else { throw SettingsError(message: "Settings could not safely edit this TOML layout. Edit the file directly.") }
        let originalTable = try TOMLTable(string: source)
        let editedTable = try TOMLTable(string: result)
        for table in [originalTable, editedTable] {
            table.remove(at: "watermark")
            if let shortcutTable = table["shortcut"]?.table {
                shortcutTable.remove(at: "key")
                shortcutTable.remove(at: "modifiers")
                if shortcutTable.count == 0 { table.remove(at: "shortcut") }
            }
        }
        guard originalTable == editedTable else {
            throw SettingsError(message: "Settings could not preserve unrelated TOML content. Edit the file directly.")
        }
        return result
    }

    private static func editableRanges(in source: String) throws -> [String: Range<String.Index>] {
        var ranges: [String: Range<String.Index>] = [:]
        var section = ""
        var position = source.startIndex
        while position < source.endIndex {
            let lineEnd = source[position...].firstIndex(where: \.isNewline) ?? source.endIndex
            let line = String(source[position..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") {
                section = trimmed.range(of: #"^\[shortcut\]\s*(#.*)?$"#, options: .regularExpression) != nil ? "shortcut" : "unrelated"
            } else if !trimmed.hasPrefix("#"), let equals = source[position..<lineEnd].firstIndex(of: "=") {
                let key = source[position..<equals].trimmingCharacters(in: .whitespaces)
                var start = source.index(after: equals)
                while start < source.endIndex, source[start] == " " || source[start] == "\t" { start = source.index(after: start) }
                var end = start
                var quote: Character?
                var triple = false
                var escaped = false
                var depth = 0
                var comment = false
                while end < source.endIndex {
                    let char = source[end]
                    if comment {
                        if char.isNewline { comment = false; if depth == 0 { break } }
                    } else if let delimiter = quote {
                        if escaped { escaped = false }
                        else if delimiter == "\"", char == "\\" { escaped = true }
                        else if char == delimiter {
                            let marker = String(repeating: String(delimiter), count: 3)
                            if !triple { quote = nil }
                            else if source[end...].hasPrefix(marker) {
                                end = source.index(end, offsetBy: 2)
                                quote = nil
                            }
                        }
                    } else if char == "#" {
                        if depth == 0 { break }; comment = true
                    } else if char.isNewline, depth == 0 { break }
                    else if char == "\"" || char == "'" {
                        quote = char
                        triple = source[end...].hasPrefix(String(repeating: String(char), count: 3))
                        if triple { end = source.index(end, offsetBy: 2) }
                    } else if char == "[" || char == "{" { depth += 1 }
                    else if char == "]" || char == "}" { depth -= 1 }
                    end = source.index(after: end)
                }
                var valueEnd = end
                while valueEnd > start, source[source.index(before: valueEnd)].isWhitespace { valueEnd = source.index(before: valueEnd) }
                let path = section.isEmpty ? key : section + "." + key
                if ["watermark", "shortcut.key", "shortcut.modifiers"].contains(path) { ranges[path] = start..<valueEnd }
                position = end
                if position < source.endIndex, source[position] == "#" {
                    position = source[position...].firstIndex(where: \.isNewline) ?? source.endIndex
                }
                if position < source.endIndex { position = source.index(after: position) }
                continue
            }
            position = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
        }
        return ranges
    }
}
