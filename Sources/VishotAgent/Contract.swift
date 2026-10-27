import Foundation

public struct AgentApp: Codable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let name: String

    public init(pid: Int32, bundleID: String?, name: String) {
        self.pid = pid; self.bundleID = bundleID; self.name = name
    }
}

public struct AgentBounds: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct AgentWindow: Codable, Equatable {
    public let id: UInt32
    public let app: AgentApp
    public let title: String
    public let bounds: AgentBounds

    public init(id: UInt32, app: AgentApp, title: String, bounds: AgentBounds) {
        self.id = id; self.app = app; self.title = title; self.bounds = bounds
    }
}

public struct AgentFailure: Codable, Error, Equatable {
    public enum Code: String, Codable {
        case invalidArguments = "invalid_arguments"
        case permissionDenied = "permission_denied"
        case startupFailed = "startup_failed"
        case timeout
        case serviceFailure = "service_failure"
        case targetUnavailable = "target_unavailable"
        case captureUnavailable = "capture_unavailable"
        case minimizedUnsupported = "minimized_unsupported"
        case encodingFailed = "encoding_failed"
        case outputWriteFailed = "output_write_failed"
        case invalidAnnotations = "invalid_annotations"
        case invalidJSON = "invalid_json"
        case invalidImage = "invalid_image"
        case renderingFailed = "rendering_failed"
        case openingFailed = "opening_failed"
    }

    public let code: Code
    public let message: String
    public let problems: [AgentValidationProblem]?
    public init(_ code: Code, _ message: String, problems: [AgentValidationProblem]? = nil) {
        self.code = code; self.message = message; self.problems = problems
    }
    public var exitStatus: Int32 {
        switch code {
        case .invalidArguments, .invalidAnnotations, .invalidJSON, .invalidImage: return 2
        case .permissionDenied: return 3
        case .startupFailed: return 4
        case .timeout: return 5
        case .serviceFailure: return 6
        case .targetUnavailable: return 7
        case .captureUnavailable, .minimizedUnsupported: return 8
        case .encodingFailed, .renderingFailed: return 9
        case .outputWriteFailed: return 10
        case .openingFailed: return 11
        }
    }
}

public struct AgentRequest: Codable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let command: String
    public let windowID: UInt32?
    /// Private service budget; the server also caps it independently.
    public var timeoutSeconds: Double = 60

    public init(command: String, windowID: UInt32? = nil) {
        schemaVersion = 1; requestID = UUID(); self.command = command; self.windowID = windowID
    }
}

/// The public JSON envelope. Request correlation is private to the transport.
public struct AgentResponse: Codable {
    public let schemaVersion: Int
    public let ok: Bool
    public let windows: [AgentWindow]?
    public let error: AgentFailure?
    public let image: AgentCapturedImage?
    public let capture: AgentCaptureFile?
    public var annotation: AgentAnnotationFile? = nil

    public static func annotated(_ file: AgentAnnotationFile, error: AgentFailure? = nil) -> Self {
        var response = Self(schemaVersion: 1, ok: error == nil, windows: nil, error: error, image: nil, capture: nil)
        response.annotation = file
        return response
    }

    public static func windows(_ windows: [AgentWindow]) -> Self {
        Self(schemaVersion: 1, ok: true, windows: windows, error: nil, image: nil, capture: nil)
    }

    public static func failure(_ error: AgentFailure) -> Self {
        Self(schemaVersion: 1, ok: false, windows: nil, error: error, image: nil, capture: nil)
    }

    public static func captured(_ image: AgentCapturedImage) -> Self {
        Self(schemaVersion: 1, ok: true, windows: nil, error: nil, image: image, capture: nil)
    }

    public static func saved(_ capture: AgentCaptureFile) -> Self {
        Self(schemaVersion: 1, ok: true, windows: nil, error: nil, image: nil, capture: capture)
    }
}

/// Private service payload. PNG bytes never appear in public CLI JSON.
public struct AgentCapturedImage: Codable {
    public let target: AgentWindow
    public let png: Data
    public let width: Int
    public let height: Int
    public init(target: AgentWindow, png: Data, width: Int, height: Int) {
        self.target = target; self.png = png; self.width = width; self.height = height
    }
}

public struct AgentCaptureFile: Codable {
    public let path: String
    public let target: AgentWindow
    public let width: Int
    public let height: Int
}

struct AgentReply: Codable {
    let requestID: UUID
    let response: AgentResponse
}
