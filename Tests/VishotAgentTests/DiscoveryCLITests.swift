import Foundation
import XCTest
import VishotAgent

final class DiscoveryCLITests: XCTestCase {
    func testVersionAndWindowsResolveExecutableThroughPATHFromUnrelatedDirectory() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.installApp(mode: "not-ready")
        try fixture.serve { .windows([]) }
        let bin = fixture.directory.appendingPathComponent("User Home/.local/bin")
        let cwd = fixture.directory.appendingPathComponent("unrelated working directory")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("vishot"), withDestinationURL: fixture.executable)
        for path in [bin.path, fixture.executable.deletingLastPathComponent().path] {
            for arguments in [["--version"], ["windows"]] {
                let result = try fixture.run(arguments, cwd: cwd, path: path + ":/usr/bin:/bin")
                XCTAssertEqual(result.status, 0, String(decoding: result.stdout, as: UTF8.self))
                XCTAssertEqual(try decode(result.stdout)["ok"] as? Bool, true)
            }
        }
    }

    func testEightDisconnectedCancellationResistantHandlersDoNotExhaustService() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let lock = NSLock()
        var calls = 0
        let entered = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "Disconnected handlers receive cancellation")
        cancelled.expectedFulfillmentCount = 8
        try fixture.serveAsyncRequest { _ in
            let call = lock.withLock { calls += 1; return calls }
            if call <= 8 {
                entered.signal()
                // A platform callback that ignores Task cancellation until it finishes.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { continuation.resume() }
                }
                if Task.isCancelled { cancelled.fulfill() }
            }
            return .windows([])
        }
        for _ in 0..<8 {
            let process = Process()
            process.executableURL = fixture.executable
            process.arguments = ["windows", "--timeout", "60"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            process.terminate()
            process.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 0.1)
        let start = ProcessInfo.processInfo.systemUptime
        let healthy = try fixture.run(["windows", "--timeout", "0.5"])
        XCTAssertEqual(healthy.status, 0, String(decoding: healthy.stdout, as: UTF8.self))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        wait(for: [cancelled], timeout: 5)
        // All late results have now arrived; no old response can reach this caller.
        XCTAssertEqual(try fixture.run(["windows", "--timeout", "0.5"]).status, 0)
    }

    func testEightExpiredHandlersReleaseCapacityWithoutWaitingForPlatformCompletion() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let lock = NSLock()
        var calls = 0
        try fixture.serveAsyncRequest { _ in
            let call = lock.withLock { calls += 1; return calls }
            if call <= 8 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 4) { continuation.resume() }
                }
            }
            return .windows([])
        }
        for _ in 0..<8 {
            XCTAssertEqual(try fixture.run(["windows", "--timeout", "0.05"]).status, 5)
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try fixture.run(["windows", "--timeout", "0.5"]).status, 0)
    }
    func testBackgroundLaunchUsesContainingAppEvenWhenAnotherInstallationIsRunning() throws {
        let first = try CLIFixture()
        let second = try CLIFixture()
        defer { first.stop(); second.stop() }
        let bundleID = "dev.vishot.fixture.\(UUID().uuidString)"
        try first.installApp(mode: "ready", bundleID: bundleID)
        try second.installApp(mode: "ready", bundleID: bundleID)
        let one = try first.run(["windows"])
        let two = try second.run(["windows", "--startup-timeout", "1"])
        XCTAssertEqual(one.status, 0)
        XCTAssertEqual(two.status, 0, String(decoding: two.stdout, as: UTF8.self))
        let firstPID = (try decode(one.stdout)["windows"] as? [[String: Any]])?.first?["app"] as? [String: Any]
        let secondPID = (try decode(two.stdout)["windows"] as? [[String: Any]])?.first?["app"] as? [String: Any]
        XCTAssertNotEqual(firstPID?["pid"] as? Int, secondPID?["pid"] as? Int)
    }

    func testVersionComesFromContainingAppWithoutStartingService() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.installApp(mode: "not-ready")
        let result = try fixture.run(["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try decode(result.stdout)["version"] as? String, "1.2.3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.appendingPathComponent("fixture.pid").path))
    }

    func testLaunchServicesStartsContainingSubstituteAppInBackground() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.installApp(mode: "ready")
        let result = try fixture.run(["windows"])
        XCTAssertEqual(result.status, 0, String(decoding: result.stdout, as: UTF8.self))
        let windows = try XCTUnwrap(try decode(result.stdout)["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["title"] as? String, "Background launch confirmed")
    }

    func testLaunchedAppWithoutReadyServiceTimesOut() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.installApp(mode: "not-ready")
        let start = ProcessInfo.processInfo.systemUptime
        let result = try fixture.run(["windows", "--startup-timeout", "0.5"])
        XCTAssertEqual(result.status, 5)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "timeout")
    }

    func testCoveredWindowsSurviveServiceDiscoveryWhileHelperAndOwnSurfacesDoNot() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let app = AgentApp(pid: 123, bundleID: "com.example.Editor", name: "Editor")
        let bounds = AgentBounds(x: 0, y: 0, width: 800, height: 600)
        func candidate(_ id: UInt32, pid: Int32 = 123, layer: Int = 0, regular: Bool = true) -> AgentWindowCandidate {
            AgentWindowCandidate(window: AgentWindow(id: id,
                app: pid == 123 ? app : AgentApp(pid: pid, bundleID: nil, name: "Helper"),
                title: "Window \(id)", bounds: bounds), layer: layer, alpha: 1, isRegularApp: regular)
        }
        let discovery = AgentDiscovery(ownPID: 999, authorized: { true }, snapshot: {
            // Both app windows occupy exactly the same bounds: the second is fully covered.
            [candidate(10), candidate(11), candidate(12, pid: 999),
             candidate(13, layer: 3), candidate(14, regular: false)]
        })
        try fixture.serveRequest { try discovery.respond(to: $0) }
        let result = try fixture.run(["windows"])
        XCTAssertEqual(result.status, 0)
        let json = try decode(result.stdout)
        XCTAssertEqual((json["windows"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }, [10, 11])
    }

    func testPermissionAndServiceFailuresHaveStructuredJSONAndDistinctExits() throws {
        for (failure, status) in [(AgentFailure(.permissionDenied, "Enable Screen Recording in Settings."), Int32(3)),
                                  (AgentFailure(.serviceFailure, "Enumeration unavailable."), Int32(6))] {
            let fixture = try CLIFixture()
            defer { fixture.stop() }
            try fixture.serve { throw failure }
            let result = try fixture.run(["windows"])
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.stderr, "")
            let json = try decode(result.stdout)
            XCTAssertEqual(json["ok"] as? Bool, false)
            XCTAssertNil(json["windows"])
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, failure.code.rawValue)
        }
    }

    func testDeniedAuthorizationNeverEnumeratesWindows() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let discovery = AgentDiscovery(ownPID: 999, authorized: { false }, snapshot: {
            XCTFail("Unauthorized discovery must not call window-system APIs")
            return []
        })
        try fixture.serveRequest { try discovery.respond(to: $0) }
        let result = try fixture.run(["windows"])
        XCTAssertEqual(result.status, 3)
        let error = try decode(result.stdout)["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "permission_denied")
        XCTAssertTrue((error?["message"] as? String)?.contains("System Settings") == true)
    }

    func testUnexpectedServiceFailureDoesNotLeakDiagnosticsOrSucceed() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serve { throw NSError(domain: "Private implementation detail", code: 123) }
        let result = try fixture.run(["windows"])
        XCTAssertEqual(result.status, 6)
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(String(decoding: result.stdout, as: UTF8.self).contains("Private implementation detail"))
        XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "service_failure")
    }

    func testServiceCanRestartAtAnExistingEndpoint() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serve { .windows([]) }
        XCTAssertEqual(try fixture.run(["windows"]).status, 0)
        try fixture.serve { .windows([]) }
        XCTAssertEqual(try fixture.run(["windows"]).status, 0)
    }

    func testInvalidArgumentsFailBeforeContactingService() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        for arguments in [[], ["capture"], ["windows", "extra"], ["windows", "--timeout", "nan"],
                          ["windows", "--timeout", "0"], ["windows", "--timeout", "61"],
                          ["windows", "--timeout", "1", "--timeout", "2"]] {
            let result = try fixture.run(arguments)
            XCTAssertEqual(result.status, 2, "\(arguments)")
            let json = try decode(result.stdout)
            XCTAssertEqual((json["error"] as? [String: Any])?["code"] as? String, "invalid_arguments")
        }
    }

    func testRequestTimeoutIsBounded() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serve { Thread.sleep(forTimeInterval: 0.4); return .windows([]) }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try fixture.run(["windows", "--timeout", "0.05"])
        XCTAssertEqual(result.status, 5)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
        XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "timeout")
    }

    func testConcurrentCallersReceiveTheirOwnCompleteResponse() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serveRequest { request in
            Thread.sleep(forTimeInterval: 0.03)
            return .windows([AgentWindow(id: 42, app: AgentApp(pid: 1, bundleID: nil, name: "Editor"),
                title: request.requestID.uuidString, bounds: AgentBounds(x: 0, y: 0, width: 200, height: 200))])
        }
        let lock = NSLock()
        var responses: [Data] = []
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            do {
                let result = try fixture.run(["windows"])
                lock.lock(); defer { lock.unlock() }
                if result.status == 0 { responses.append(result.stdout) }
                else { failures.append(String(decoding: result.stdout, as: UTF8.self)) }
            } catch { lock.lock(); failures.append("\(error)"); lock.unlock() }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(responses.count, 6)
        let titles = try responses.map { try XCTUnwrap((decode($0)["windows"] as? [[String: Any]])?.first?["title"] as? String) }
        XCTAssertEqual(Set(titles).count, 6)
    }

    func testMissingAppReturnsStartupFailureWithoutUI() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        let result = try fixture.run(["windows", "--startup-timeout", "1"])
        XCTAssertEqual(result.status, 4)
        XCTAssertEqual((try decode(result.stdout)["error"] as? [String: Any])?["code"] as? String, "startup_failed")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCompiledCLIListsExactLiveMetadataIncludingCoveredWindows() throws {
        let fixture = try CLIFixture()
        defer { fixture.stop() }
        try fixture.serve {
            .windows([
                AgentWindow(id: 42, app: AgentApp(pid: 123, bundleID: "com.example.Editor", name: "Editor"),
                            title: "Document — covered", bounds: AgentBounds(x: -800, y: 30, width: 800, height: 600)),
            ])
        }
        let result = try fixture.run(["windows"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["ok"] as? Bool, true)
        let windows = try XCTUnwrap(json["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0]["id"] as? Int, 42)
        XCTAssertEqual(windows[0]["title"] as? String, "Document — covered")
        XCTAssertEqual((windows[0]["app"] as? [String: Any])?["bundleID"] as? String, "com.example.Editor")
        XCTAssertEqual((windows[0]["bounds"] as? [String: Any])?["x"] as? Double, -800)
    }
}

final class CLIFixture {
    let directory: URL
    let app: URL
    let executable: URL
    private var server: AgentServer?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vishot CLI tests \(UUID())")
        app = directory.appendingPathComponent("Vishot.app")
        executable = app.appendingPathComponent("Contents/Helpers/vishot")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bin = Bundle(for: DiscoveryCLITests.self).bundleURL.deletingLastPathComponent()
        try FileManager.default.copyItem(at: bin.appendingPathComponent("VishotCLI"), to: executable)
    }

    func serve(_ handler: @escaping () throws -> AgentResponse) throws {
        try serveRequest { _ in try handler() }
    }

    func installApp(mode: String, bundleID: String = "dev.vishot.fixture.\(UUID().uuidString)") throws {
        let bin = Bundle(for: DiscoveryCLITests.self).bundleURL.deletingLastPathComponent()
        let main = app.appendingPathComponent("Contents/MacOS/AgentServiceFixture")
        try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bin.appendingPathComponent("AgentServiceFixture"), to: main)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "AgentServiceFixture", "CFBundlePackageType": "APPL", "LSUIElement": true,
            "FixtureMode": mode, "CFBundleShortVersionString": "1.2.3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    func serveRequest(_ handler: @escaping (AgentRequest) throws -> AgentResponse) throws {
        try serveAsyncRequest { try handler($0) }
    }

    func serveAsyncRequest(_ handler: @escaping (AgentRequest) async throws -> AgentResponse) throws {
        server?.stop()
        server = nil
        server = try AgentServer(endpoint: AgentEndpoint(appURL: app), handler: handler)
        try server?.start()
    }

    func run(_ arguments: [String], cwd: URL? = nil, path: String? = nil) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd ?? directory
        if let path {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["vishot"] + arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func stop() {
        server?.stop()
        if let data = try? Data(contentsOf: app.appendingPathComponent("fixture.pid")),
           let pid = Int32(String(decoding: data, as: UTF8.self)) { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(atPath: AgentEndpoint(appURL: app).directory)
    }
}
