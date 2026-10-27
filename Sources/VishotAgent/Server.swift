import Darwin
import Foundation

/// A bounded worker pool, independent of the app's main thread and picker path.
public final class AgentServer {
    private let endpoint: AgentEndpoint
    private let handler: (AgentRequest) async throws -> AgentResponse
    private let queue = DispatchQueue(label: "dev.vishot.agent.accept")
    private let workers = DispatchQueue(label: "dev.vishot.agent.requests", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var socketFD: Int32 = -1

    public init(endpoint: AgentEndpoint, handler: @escaping (AgentRequest) async throws -> AgentResponse) throws {
        self.endpoint = endpoint; self.handler = handler
    }

    public func start() throws {
        try endpoint.prepare()
        lockFD = open(endpoint.directory + "/service.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            stop(); throw socketFailure("A service already owns this app's endpoint.")
        }
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { stop(); throw socketFailure("Could not create the service socket.") }
        configureSocket(socketFD)
        unlink(endpoint.socketPath)
        var address = try socketAddress(endpoint.socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(endpoint.socketPath, 0o600) == 0, listen(socketFD, 32) == 0 else {
            stop(); throw socketFailure("Could not listen on the user-local service socket.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        let fd = socketFD
        source.setEventHandler { [weak self] in self?.acceptRequests(on: fd) }
        // The source owns the descriptor so stop cannot race an accept on a recycled fd.
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func acceptRequests(on socket: Int32) {
        while true {
            let fd = accept(socket, nil, nil)
            guard fd >= 0 else { return }
            configureSocket(fd)
            guard slots.wait(timeout: .now()) == .success else { close(fd); continue }
            workers.async { [handler, slots] in
                defer { close(fd); slots.signal() }
                let deadline = ProcessInfo.processInfo.systemUptime + 65
                do {
                    try verifyPeer(fd)
                    let request = try AgentWire.receive(AgentRequest.self, fd: fd, deadline: deadline)
                    let response: AgentResponse
                    if request.schemaVersion != 1 {
                        response = .failure(AgentFailure(.serviceFailure, "Incompatible CLI and app protocol. Update the app and its CLI together."))
                    } else {
                        response = try Self.runHandler(handler, request: request, fd: fd)
                    }
                    try AgentWire.send(AgentReply(requestID: request.requestID, response: response), fd: fd, deadline: deadline)
                } catch { /* A disconnected or invalid client has no response channel. */ }
            }
        }
    }

    private static func runHandler(_ handler: @escaping (AgentRequest) async throws -> AgentResponse,
                                   request: AgentRequest, fd: Int32) throws -> AgentResponse {
        let completion = HandlerCompletion()
        // An unstructured task is intentional: a structured group would wait forever
        // for an uncooperative platform callback even after cancelling its child.
        let task = Task.detached {
            let response: AgentResponse
            do {
                try Task.checkCancellation()
                response = try await handler(request)
            } catch let error as AgentFailure { response = .failure(error) }
            catch { response = .failure(socketFailure("The Vishot service could not complete the request.")) }
            completion.finish(response)
        }
        defer { completion.abandon(); task.cancel() }
        let budget = request.timeoutSeconds.isFinite ? min(60, max(0.05, request.timeoutSeconds)) : 5
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        while true {
            if let response = completion.take() { return response }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return .failure(AgentFailure(.timeout, "The Vishot service handler exceeded its request deadline."))
            }
            var peer = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&peer, 1, 10)
            if result > 0 {
                // One request per connection: EOF, socket errors, or extra bytes all
                // end this request. Only this worker owns the fd and can close it.
                throw socketFailure("The service caller disconnected or sent unexpected data.")
            }
            if result < 0 && errno != EINTR { throw socketFailure("Could not monitor the service caller.") }
        }
    }

    public func stop() {
        if let source {
            source.cancel()
            self.source = nil
        } else if socketFD >= 0 { close(socketFD) }
        socketFD = -1
        if lockFD >= 0 {
            // Only the lock owner may remove the endpoint.
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { unlink(endpoint.socketPath) }
            close(lockFD); lockFD = -1
        }
    }

    deinit { stop() }
}

/// A late platform completion holds only this gate, never a socket or worker slot.
private final class HandlerCompletion {
    private let lock = NSLock()
    private var active = true
    private var response: AgentResponse?

    func finish(_ response: AgentResponse) {
        lock.withLock { if active { self.response = response } }
    }

    func take() -> AgentResponse? {
        lock.withLock {
            defer { response = nil }
            return response
        }
    }

    func abandon() { lock.withLock { active = false; response = nil } }
}
