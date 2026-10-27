import CryptoKit
import Darwin
import Foundation

/// Each installed app owns an endpoint: a moved app or another build cannot serve its CLI.
public struct AgentEndpoint {
    public let directory: String
    public let socketPath: String
    public let appURL: URL
    public static let backgroundArgument = "--vishot-agent-background"

    public init(appURL: URL) {
        self.appURL = appURL.resolvingSymlinksInPath().standardizedFileURL
        let digest = SHA256.hash(data: Data(self.appURL.path.utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        directory = "/tmp/vishot-agent-\(getuid())-\(digest)"
        socketPath = directory + "/service.sock"
    }

    public static func containingApp(executableURL: URL) throws -> URL {
        let executable = executableURL.resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", executable.deletingLastPathComponent().lastPathComponent == "Helpers",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            throw AgentFailure(.startupFailed, "Run the CLI bundled inside an installed Vishot.app. Open Vishot manually to complete setup.")
        }
        return app
    }

    func prepare() throws {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw socketFailure("Could not create the user-local service directory.") }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw AgentFailure(.serviceFailure, "The service directory is not a private directory owned by this user.")
        }
    }
}

func socketFailure(_ message: String) -> AgentFailure { AgentFailure(.serviceFailure, message) }

func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw socketFailure("Service path is too long.") }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

func configureSocket(_ fd: Int32) {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
}

func verifyPeer(_ fd: Int32) throws {
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
        throw socketFailure("The service peer is not owned by this user.")
    }
}

func waitForSocket(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AgentFailure(.timeout, "The Vishot service did not respond before the deadline.") }
        var item = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&item, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
        if result > 0 {
            guard item.revents & events != 0 else { throw socketFailure("The Vishot service disconnected.") }
            return
        }
        if result < 0 && errno != EINTR { throw socketFailure("Could not wait for the Vishot service.") }
    }
}

// Length-prefixed frames bound memory use even for a malfunctioning peer.
enum AgentWire {
    static let maxBytes = 128 * 1024 * 1024

    static func send<T: Encodable>(_ value: T, fd: Int32, deadline: TimeInterval) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxBytes else { throw socketFailure("The service response exceeds the message limit.") }
        var length = UInt32(data.count).bigEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + data
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try waitForSocket(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw socketFailure("Could not send the service request.") }
                offset += count
            }
        }
    }

    static func receive<T: Decodable>(_ type: T.Type, fd: Int32, deadline: TimeInterval) throws -> T {
        let header = try read(4, fd: fd, deadline: deadline)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maxBytes else { throw socketFailure("Invalid service message size.") }
        do { return try JSONDecoder().decode(type, from: read(size, fd: fd, deadline: deadline)) }
        catch let error as AgentFailure { throw error }
        catch { throw socketFailure("The Vishot service returned an invalid message.") }
    }

    private static func read(_ size: Int, fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < size {
                try waitForSocket(fd, events: Int16(POLLIN), deadline: deadline)
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), size - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw socketFailure("The Vishot service disconnected before completing its response.") }
                offset += count
            }
        }
        return data
    }
}
