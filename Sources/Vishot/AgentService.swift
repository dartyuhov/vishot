import AppKit
import VishotAgent

/// All window-system work happens only for service requests, off the main thread.
enum AgentService {
    static func start() throws -> AgentServer {
        let discovery = AgentDiscovery(
            ownPID: ProcessInfo.processInfo.processIdentifier,
            authorized: { CGPreflightScreenCaptureAccess() },
            snapshot: snapshot
        )
        let server = try AgentServer(endpoint: AgentEndpoint(appURL: Bundle.main.bundleURL)) {
            if $0.command == "capture" {
                guard let id = $0.windowID, id > 0 else { throw AgentFailure(.invalidArguments, "Capture requires a positive window ID.") }
                return try await AgentWindowCapture.capture(id: id)
            }
            return try discovery.respond(to: $0)
        }
        try server.start()
        return server
    }

    private static func snapshot() throws -> [AgentWindowCandidate] {
        guard let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw AgentFailure(.serviceFailure, "macOS could not enumerate windows. Retry after reopening Vishot.")
        }
        var apps: [pid_t: NSRunningApplication] = [:]
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let app = apps[pid] ?? NSRunningApplication(processIdentifier: pid)
            apps[pid] = app
            return AgentWindowCandidate(
                window: AgentWindow(id: id,
                    app: AgentApp(pid: pid, bundleID: app?.bundleIdentifier,
                                  name: app?.localizedName ?? entry[kCGWindowOwnerName as String] as? String ?? ""),
                    title: entry[kCGWindowName as String] as? String ?? "",
                    bounds: AgentBounds(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)),
                layer: layer, alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                isRegularApp: app?.activationPolicy == .regular)
        }
    }
}
