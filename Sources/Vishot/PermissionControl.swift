import AppKit
import ApplicationServices

enum CapturePermission: CaseIterable {
    case screenRecording, accessibility

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        }
    }

    var requirement: String {
        self == .screenRecording ? "Required" : "Optional · Recommended"
    }

    var explanation: String {
        switch self {
        case .screenRecording: return "Required to capture screenshots."
        case .accessibility: return "Temporarily brings keyboard-selected windows forward and lets you select UI elements. Without access, window navigation remains available, but selected windows are not brought forward and element selection is unavailable."
        }
    }

    var pageURL: URL {
        let pane = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    var instructions: String {
        let page = self == .screenRecording ? "Screen Recording (Screen & System Audio Recording on newer macOS versions)" : "Accessibility"
        let addInstructions = self == .accessibility ? " If Vishot is missing from the list, click Add (+), locate the Vishot application, and click Open, then enable Vishot." : ""
        return "Open System Settings → Privacy & Security → \(page), then enable Vishot.\(addInstructions) Return here to check access. If macOS asks you to quit and reopen Vishot, do so before checking again."
    }

    func readAccess() -> Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }
}

/// Transient permission-control state; authorization always comes from macOS.
struct PermissionControl {
    let permission: CapturePermission
    private let readAccess: () -> Bool
    private let requestScreenAccess: () -> Bool
    private let openPage: (URL) -> Bool
    private(set) var isAllowed: Bool
    private(set) var openingError: String?

    init(permission: CapturePermission, readAccess: (() -> Bool)? = nil,
         requestScreenAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         openPage: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.permission = permission
        let read = readAccess ?? { permission.readAccess() }
        self.readAccess = read
        self.requestScreenAccess = requestScreenAccess
        self.openPage = openPage
        isAllowed = read()
    }

    mutating func refresh() { isAllowed = readAccess() }

    mutating func enable() {
        // Register a fresh app with TCC only in response to Enable. The request's
        // result is not our status: preflight below reports access for this process.
        if permission == .screenRecording { _ = requestScreenAccess() }
        openingError = openPage(permission.pageURL) ? nil : "Couldn’t open System Settings. \(permission.instructions)"
        refresh()
    }
}
