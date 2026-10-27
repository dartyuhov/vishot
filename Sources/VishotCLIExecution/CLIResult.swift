import Foundation
import VishotAgent

/// One complete public JSON line and its process status. No transport image bytes escape here.
public struct CLIResult {
    public let output: Data
    public let exitStatus: Int32

    init(response: AgentResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response) {
            output = data + Data([10])
            exitStatus = response.error?.exitStatus ?? 0
        } else {
            output = Data()
            exitStatus = 6
        }
    }

    init(version: String) throws {
        output = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "ok": true, "version": version],
            options: [.sortedKeys]) + Data([10])
        exitStatus = 0
    }

    /// A failed stdout write is a process I/O failure, independent of the command's outcome.
    public static let outputFailureStatus: Int32 = 6
}

extension AgentFailure {
    var exitStatus: Int32 {
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
