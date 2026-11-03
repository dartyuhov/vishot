import XCTest
import VishotAgent
@testable import VishotCLIExecution

final class CLIExecutionTests: XCTestCase {
    func testInvalidCommandsRejectBeforeResolvingInstallationOrStartingCapture() throws {
        for arguments in [[], ["unknown"], ["annotate"], ["capture"],
                          ["capture", "--window-id", "0"], ["windows", "--timeout", "NaN"],
                          ["windows", "--timeout", "0.01"], ["windows", "--timeout", "61"],
                          ["windows", "--timeout", "1", "--timeout", "2"], ["windows", "--open"]] {
            var resolved = false
            let result = CLIExecution.execute(arguments, executableURL: {
                resolved = true
                throw CocoaError(.fileReadUnknown)
            })
            XCTAssertFalse(resolved, "\(arguments)")
            XCTAssertEqual(result.exitStatus, 2)
            let response = try JSONDecoder().decode(AgentResponse.self, from: result.output)
            XCTAssertEqual(response.schemaVersion, 1)
            XCTAssertEqual(response.error?.code, .invalidArguments)
            XCTAssertNil(response.image)
            XCTAssertEqual(result.output.last, 10)
        }
    }

    func testExecutableResolutionFailureRetainsStartupFailureMessageAndStatus() throws {
        let result = CLIExecution.execute(["--version"], executableURL: { throw CocoaError(.fileReadUnknown) })
        XCTAssertEqual(result.exitStatus, 4)
        let response = try JSONDecoder().decode(AgentResponse.self, from: result.output)
        XCTAssertEqual(response.error?.code, .startupFailed)
        XCTAssertEqual(response.error?.message, "Could not resolve the running Vishot CLI executable.")
    }

    func testStructuredFailuresKeepEveryExistingExitStatus() throws {
        let cases: [(AgentFailure.Code, Int32)] = [
            (.invalidArguments, 2), (.invalidAnnotations, 2), (.invalidJSON, 2), (.invalidImage, 2),
            (.permissionDenied, 3), (.startupFailed, 4), (.timeout, 5), (.serviceFailure, 6),
            (.targetUnavailable, 7), (.captureUnavailable, 8), (.minimizedUnsupported, 8),
            (.encodingFailed, 9), (.renderingFailed, 9), (.outputWriteFailed, 10), (.openingFailed, 11)]
        for (code, status) in cases {
            let result = CLIResult(response: .failure(AgentFailure(code, "fixture failure")))
            XCTAssertEqual(result.exitStatus, status)
            let response = try JSONDecoder().decode(AgentResponse.self, from: result.output)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, code)
            XCTAssertEqual(response.error?.message, "fixture failure")
            XCTAssertNil(response.image)
        }
    }
}
