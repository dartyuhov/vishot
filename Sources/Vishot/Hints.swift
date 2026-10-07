import Carbon.HIToolbox

/// Vimium-style hints for hint mode. All hints have the same length, so a hint is complete as soon
/// as it is typed.
enum Hints {
    /// Home row first, then the rows above and below.
    private static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)

    /// Key codes, not characters, as with every other key, so hints work with non-Latin layouts.
    private static let keyCodes: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z",
    ]

    /// At most 26 × 26 hints.
    static func make(count: Int) -> [String] {
        if count <= alphabet.count { return Array(alphabet.prefix(count)) }
        let pairs = alphabet.lazy.flatMap { first in alphabet.lazy.map { first + $0 } }
        return Array(pairs.prefix(count))
    }

    static func letter(forKeyCode keyCode: Int) -> String? {
        keyCodes[keyCode]
    }
}
