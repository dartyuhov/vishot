import Carbon.HIToolbox

public struct CaptureShortcut: Equatable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let defaults = CaptureShortcut(key: "S", modifiers: ["command", "shift"])
    public static let modifierNames = ["command", "control", "option", "shift"]
    public static let keys: [(String, Int)] = [
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

    public var keyCode: Int { Self.keys.first { $0.0 == key }!.1 }
    public var carbonModifiers: Int {
        modifiers.reduce(0) { $0 | ["command": cmdKey, "control": controlKey, "option": optionKey, "shift": shiftKey][$1]! }
    }
    public var display: String {
        [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1).joined() + key
    }

    public func validated() throws -> CaptureShortcut {
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
