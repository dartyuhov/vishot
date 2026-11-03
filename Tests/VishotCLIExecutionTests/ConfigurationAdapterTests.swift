import XCTest
import VishotConfiguration
import VishotAgent
@testable import VishotCLIExecution

final class ConfigurationAdapterTests: XCTestCase {
    func testAnnotationSnapshotAdapterPreservesInvalidArgumentsFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "style = 'smooth'\n[history]\nretention_days = 2"
        try source.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AnnotationCommand.annotationStyleSnapshot(url: url)) { error in
            guard let failure = error as? AgentFailure else { return XCTFail("Expected AgentFailure, got \(error)") }
            XCTAssertEqual(failure.code, .invalidArguments)
            XCTAssertEqual(failure.exitStatus, 2)
            XCTAssertEqual(failure.message, "Could not resolve the selected annotation style from \(url.path): history.retention_days must be 0, 1, 3, 7, or 30.")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), source)
    }
}
