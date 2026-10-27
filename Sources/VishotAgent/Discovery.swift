import Foundation

/// Snapshot supplied by the window-system adapter. Visibility is deliberately absent:
/// covered and off-Space windows are eligible whenever the system reports them.
public struct AgentWindowCandidate {
    public let window: AgentWindow
    public let layer: Int
    public let alpha: Double
    public let isRegularApp: Bool

    public init(window: AgentWindow, layer: Int, alpha: Double, isRegularApp: Bool) {
        self.window = window; self.layer = layer; self.alpha = alpha; self.isRegularApp = isRegularApp
    }
}

/// Service boundary shared by the live adapter and controlled CLI fixtures.
public struct AgentDiscovery {
    private let ownPID: Int32
    private let authorized: () -> Bool
    private let snapshot: () throws -> [AgentWindowCandidate]

    public init(ownPID: Int32, authorized: @escaping () -> Bool,
                snapshot: @escaping () throws -> [AgentWindowCandidate]) {
        self.ownPID = ownPID; self.authorized = authorized; self.snapshot = snapshot
    }

    public func respond(to request: AgentRequest) throws -> AgentResponse {
        guard request.command == "windows" else { throw AgentFailure(.invalidArguments, "Unknown service command.") }
        guard authorized() else {
            throw AgentFailure(.permissionDenied, "Allow Screen Recording for Vishot in System Settings > Privacy & Security, then reopen Vishot manually and retry. No permission prompt was opened.")
        }
        let windows = try snapshot().filter {
            let frame = $0.window.bounds
            return $0.window.app.pid != ownPID && $0.window.app.bundleID != "com.dartsiukhou.vishot"
                && $0.isRegularApp && $0.layer == 0 && $0.alpha > 0
                && frame.x.isFinite && frame.y.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }.map(\.window).sorted { $0.id < $1.id }
        return .windows(windows)
    }
}
