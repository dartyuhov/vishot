import Darwin
import Foundation

public struct AgentClient {
    private let endpoint: AgentEndpoint
    public init(endpoint: AgentEndpoint) { self.endpoint = endpoint }

    /// Launch is injected at the service boundary; it must return within its deadline.
    public func windows(startupTimeout: TimeInterval = 5, requestTimeout: TimeInterval = 5,
                        launch: (URL, TimeInterval) throws -> Void) throws -> AgentResponse {
        try perform(AgentRequest(command: "windows"), startupTimeout: startupTimeout, requestTimeout: requestTimeout, launch: launch)
    }

    public func perform(_ request: AgentRequest, startupTimeout: TimeInterval = 5, requestTimeout: TimeInterval = 5,
                        launch: (URL, TimeInterval) throws -> Void) throws -> AgentResponse {
        try endpoint.prepare()
        var fd = try connectIfAvailable()
        if fd == nil {
            let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
            try launch(endpoint.appURL, startupTimeout)
            repeat {
                fd = try connectIfAvailable()
                if fd != nil { break }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AgentFailure(.timeout, "Vishot launched but its service did not become ready before the startup deadline. Open Vishot manually and retry.")
                }
                Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            } while true
        }
        let connection = fd!
        defer { close(connection) }
        try verifyPeer(connection)
        let deadline = ProcessInfo.processInfo.systemUptime + requestTimeout
        var request = request
        request.timeoutSeconds = requestTimeout
        try AgentWire.send(request, fd: connection, deadline: deadline)
        let reply = try AgentWire.receive(AgentReply.self, fd: connection, deadline: deadline)
        guard reply.requestID == request.requestID, reply.response.schemaVersion == 1,
              reply.response.ok ? (reply.response.error == nil && reply.response.capture == nil &&
                (request.command == "windows" ? (reply.response.windows != nil && reply.response.image == nil)
                 : (reply.response.image?.target.id == request.windowID && reply.response.windows == nil)))
                : (reply.response.error != nil && reply.response.windows == nil && reply.response.image == nil && reply.response.capture == nil) else {
            throw socketFailure("The Vishot service returned an incompatible or uncorrelated response.")
        }
        return reply.response
    }

    private func connectIfAvailable() throws -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketFailure("Could not create a service connection.") }
        configureSocket(fd)
        var address = try socketAddress(endpoint.socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result == 0 { return fd }
        let code = errno
        close(fd)
        if code == ENOENT || code == ECONNREFUSED { return nil }
        throw socketFailure("Could not connect to Vishot's user-local service. Retry when the app is ready.")
    }
}
