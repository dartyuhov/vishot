import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import VishotAgent

final class CaptureCLITests: XCTestCase {
    func testShippedSkillShellExamplesRunAgainstCompiledCLIAndYieldReadableImage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: root.appendingPathComponent("skills/vishot-capture/SKILL.md"), encoding: .utf8)
        let shell = try XCTUnwrap(skill.components(separatedBy: "```sh\n").dropFirst().first?.components(separatedBy: "```").first)
        let commands = shell.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(commands.count, 2)
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        try fixture.serveRequest { request in
            switch request.command {
            case "windows": return .windows([self.target(42)])
            case "capture":
                guard request.windowID == 42 else { throw AgentFailure(.targetUnavailable, "Wrong example ID") }
                return .captured(AgentCapturedImage(target: self.target(42), png: png, width: 3, height: 2))
            default: throw AgentFailure(.invalidArguments, "Unknown example command")
            }
        }
        var result: [String: Any] = [:]
        for command in commands {
            XCTAssertEqual(command.first, "vishot")
            let executed = try fixture.run(Array(command.dropFirst()))
            XCTAssertEqual(executed.status, 0, String(decoding: executed.stdout, as: UTF8.self))
            result = try decode(executed.stdout)
        }
        let capture = try XCTUnwrap(result["capture"] as? [String: Any])
        let path = try XCTUnwrap(capture["path"] as? String)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testTerminatedCallerNeverWritesAndDoesNotAffectAnotherCapture() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        let entered = DispatchSemaphore(value: 0)
        try fixture.serveRequest { request in
            if request.windowID == 42 {
                entered.signal()
                Thread.sleep(forTimeInterval: 0.4)
            }
            return .captured(AgentCapturedImage(target: self.target(request.windowID!), png: png, width: 3, height: 2))
        }
        let process = Process()
        process.executableURL = fixture.executable
        process.currentDirectoryURL = fixture.directory
        process.arguments = ["capture", "--window-id", "42"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        process.terminate()
        process.waitUntilExit()
        let next = try fixture.run(["capture", "--window-id", "43"])
        XCTAssertEqual(next.status, 0)
        Thread.sleep(forTimeInterval: 0.5)
        let folder = fixture.directory.appendingPathComponent(".vishot")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("window-43-"))
    }

    func testCaptureBackgroundLaunchAndStartupFailureAreStructured() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let failed = try fixture.run(["capture", "--window-id", "42"])
        XCTAssertEqual(failed.status, 4)
        XCTAssertNil(try decode(failed.stdout)["capture"])
        try fixture.installApp(mode: "ready")
        let captured = try fixture.run(["capture", "--window-id", "42"])
        XCTAssertEqual(captured.status, 0, String(decoding: captured.stdout, as: UTF8.self))
        let file = try XCTUnwrap(try decode(captured.stdout)["capture"] as? [String: Any])
        let path = try XCTUnwrap(file["path"] as? String)
        XCTAssertNotNil(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    }

    func testCaptureRefusesOutputDirectorySymlink() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let outside = fixture.directory.appendingPathComponent("another workspace")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent(".vishot"), withDestinationURL: outside)
        let png = try makePNG()
        try fixture.serve { .captured(AgentCapturedImage(target: self.target(42), png: png, width: 3, height: 2)) }
        XCTAssertEqual(try fixture.run(["capture", "--window-id", "42"]).status, 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
    func testExactWindowCapturePublishesImmediatelyDecodablePNGInCallerWorkspace() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        try fixture.serveRequest { request in
            XCTAssertEqual(request.command, "capture")
            XCTAssertEqual(request.windowID, 42)
            return .captured(AgentCapturedImage(target: self.target(42), png: png, width: 3, height: 2))
        }
        let workspace = fixture.directory.appendingPathComponent("caller workspace with spaces")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let result = try fixture.run(["capture", "--window-id", "42"], cwd: workspace)
        XCTAssertEqual(result.status, 0, String(decoding: result.stdout, as: UTF8.self))
        XCTAssertEqual(result.stderr, "")
        let json = try decode(result.stdout)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let capture = try XCTUnwrap(json["capture"] as? [String: Any])
        let path = try XCTUnwrap(capture["path"] as? String)
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path,
                       workspace.appendingPathComponent(".vishot").resolvingSymlinksInPath().path)
        XCTAssertEqual((capture["target"] as? [String: Any])?["id"] as? Int, 42)
        XCTAssertEqual(capture["width"] as? Int, 3)
        XCTAssertEqual(capture["height"] as? Int, 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        XCTAssertNil(json["image"])
    }

    func testInvalidCaptureArgumentsDoNotCreateOutputOrCallService() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serve { XCTFail("Invalid capture must not contact service"); return .windows([]) }
        for arguments in [["capture"], ["capture", "--window-id", "0"], ["capture", "--window-id", "-1"],
                          ["capture", "--window-id", "4294967296"], ["capture", "--window-id", "+42"],
                          ["capture", "--window-id", "42", "--window-id", "43"],
                          ["capture", "--window-id", "4.2"], ["capture", "--window-id", "42", "extra"]] {
            let result = try fixture.run(arguments)
            XCTAssertEqual(result.status, 2, "\(arguments)")
            XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".vishot").path))
    }

    func testCaptureFailuresNeverPublishOrReturnOlderImages() throws {
        let failures: [(AgentFailure.Code, Int32)] = [(.targetUnavailable, 7), (.permissionDenied, 3),
            (.captureUnavailable, 8), (.minimizedUnsupported, 8), (.encodingFailed, 9), (.serviceFailure, 6)]
        for (code, exit) in failures {
            let fixture = try CLIFixture()
            defer { fixture.stop() }
            let folder = fixture.directory.appendingPathComponent(".vishot")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let old = folder.appendingPathComponent("old.png")
            let png = try makePNG()
            try png.write(to: old)
            try fixture.serveRequest { request in
                XCTAssertEqual(request.windowID, 42)
                throw AgentFailure(code, "Controlled failure")
            }
            let result = try fixture.run(["capture", "--window-id", "42"])
            XCTAssertEqual(result.status, exit)
            XCTAssertEqual(result.stderr, "")
            let json = try decode(result.stdout)
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, code.rawValue)
            XCTAssertNil(json["capture"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["old.png"])
            XCTAssertEqual(try Data(contentsOf: old), png)
        }
    }

    func testMalformedMismatchedOrTruncatedPNGIsNotPublished() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        for (data, width) in [(Data("not PNG".utf8), 3), (png, 99), (Data(png.prefix(20)), 3)] {
            try fixture.serve { .captured(AgentCapturedImage(target: self.target(42), png: data, width: width, height: 2)) }
            let result = try fixture.run(["capture", "--window-id", "42"])
            XCTAssertEqual(result.status, 9)
            XCTAssertNil(try decode(result.stdout)["capture"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".vishot").path))
        }
    }

    func testServiceCannotSubstituteAnotherTarget() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        try fixture.serve { .captured(AgentCapturedImage(target: self.target(43), png: png, width: 3, height: 2)) }
        let result = try fixture.run(["capture", "--window-id", "42"])
        XCTAssertEqual(result.status, 6)
        XCTAssertNil(try decode(result.stdout)["capture"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".vishot").path))
    }

    func testUnwritableOutputAndConflictingDirectoryNeverSucceed() throws {
        for conflict in [false, true] {
            let fixture = try CLIFixture()
            defer { fixture.stop() }
            let png = try makePNG()
            try fixture.serve { .captured(AgentCapturedImage(target: self.target(42), png: png, width: 3, height: 2)) }
            let folder = fixture.directory.appendingPathComponent(".vishot")
            if conflict { try Data("preserve me".utf8).write(to: folder) }
            else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                          attributes: [.posixPermissions: 0o500]) }
            defer { if !conflict { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) } }
            let result = try fixture.run(["capture", "--window-id", "42"])
            XCTAssertEqual(result.status, 10)
            XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "output_write_failed")
            XCTAssertNil(try decode(result.stdout)["capture"])
            if conflict { XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "preserve me") }
            else { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), []) }
        }
    }

    func testConcurrentCapturesPublishUniqueCompleteFilesAndPreserveExistingFiles() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        let folder = fixture.directory.appendingPathComponent(".vishot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("previous.png")
        try png.write(to: old)
        try fixture.serveRequest { request in
            .captured(AgentCapturedImage(target: self.target(request.windowID!), png: png, width: 3, height: 2))
        }
        let lock = NSLock()
        var paths: [String] = [], failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            do {
                let result = try fixture.run(["capture", "--window-id", "\(42 + index)"])
                let json = try self.decode(result.stdout)
                let capture = try XCTUnwrap(json["capture"] as? [String: Any])
                let path = try XCTUnwrap(capture["path"] as? String)
                XCTAssertEqual(result.status, 0)
                XCTAssertEqual((capture["target"] as? [String: Any])?["id"] as? Int, 42 + index)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
                lock.lock(); paths.append(path); lock.unlock()
            } catch { lock.lock(); failures.append("\(error)"); lock.unlock() }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(Set(paths).count, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 7)
        XCTAssertEqual(try Data(contentsOf: old), png)
    }

    func testTimedOutCaptureCannotPublishLaterOrContaminateNextCaller() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let png = try makePNG()
        try fixture.serveRequest { request in
            if request.windowID == 42 { Thread.sleep(forTimeInterval: 0.5) }
            return .captured(AgentCapturedImage(target: self.target(request.windowID!), png: png, width: 3, height: 2))
        }
        let timedOut = try fixture.run(["capture", "--window-id", "42", "--timeout", "0.05"])
        XCTAssertEqual(timedOut.status, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(".vishot").path))
        let next = try fixture.run(["capture", "--window-id", "43"])
        XCTAssertEqual(next.status, 0)
        let capture = try XCTUnwrap(try decode(next.stdout)["capture"] as? [String: Any])
        XCTAssertEqual((capture["target"] as? [String: Any])?["id"] as? Int, 43)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent(".vishot").path).count, 1)
    }

    func target(_ id: UInt32) -> AgentWindow {
        AgentWindow(id: id, app: AgentApp(pid: 123, bundleID: "com.example.Editor", name: "Editor"),
                    title: "Covered document", bounds: AgentBounds(x: -500, y: 20, width: 300, height: 200))
    }

    func makePNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
