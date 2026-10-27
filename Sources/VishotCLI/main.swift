import AppKit
import MachO
import VishotAgent

private func executableURL() throws -> URL {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw AgentFailure(.startupFailed, "Could not resolve the running Vishot CLI executable.")
    }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

private func launchApp(_ url: URL, timeout: TimeInterval) throws {
    let completed = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var failed = false
    DispatchQueue.main.async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Launch Services otherwise reuses a running app with the same bundle ID
        // even when it lives at another path (for example, an older installation).
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.arguments = [AgentEndpoint.backgroundArgument]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            lock.lock(); failed = error != nil || app == nil; lock.unlock()
            completed.signal()
        }
    }
    guard completed.wait(timeout: .now() + timeout) == .success else {
        throw AgentFailure(.timeout, "Launch Services did not finish starting Vishot before the startup deadline.")
    }
    lock.lock(); let didFail = failed; lock.unlock()
    if didFail { throw AgentFailure(.startupFailed, "Could not background-launch the containing Vishot.app. Open the installed app manually and retry.") }
}

private func run() -> Int32 {
    let response: AgentResponse
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--version"] {
            let app = try AgentEndpoint.containingApp(executableURL: executableURL())
            guard let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                throw AgentFailure(.startupFailed, "The containing app has no release version.")
            }
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "ok": true, "version": version], options: [.sortedKeys])
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            return 0
        }
        var startupTimeout: TimeInterval = 5, requestTimeout: TimeInterval = 5
        guard let command = arguments.first, ["windows", "capture"].contains(command) else {
            throw AgentFailure(.invalidArguments, "Usage: vishot windows | vishot capture --window-id <id> [--startup-timeout <seconds>] [--timeout <seconds>]")
        }
        var windowID: UInt32?
        var index = 1
        var seen = Set<String>()
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--window-id", command == "capture", seen.insert(flag).inserted,
               index + 1 < arguments.count {
                let value = arguments[index + 1]
                guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let id = UInt32(value), id > 0 else {
                    throw AgentFailure(.invalidArguments, "--window-id requires an exact positive UInt32 window ID from vishot windows.")
                }
                windowID = id; index += 2; continue
            }
            guard ["--startup-timeout", "--timeout"].contains(flag), seen.insert(flag).inserted,
                  index + 1 < arguments.count, let seconds = Double(arguments[index + 1]),
                  seconds.isFinite, seconds >= 0.05, seconds <= 60 else {
                throw AgentFailure(.invalidArguments, "Unknown or duplicate option, or invalid timeout. Use vishot windows or vishot capture --window-id <id>, with optional --startup-timeout and --timeout values from 0.05 to 60 seconds.")
            }
            if flag == "--timeout" { requestTimeout = seconds } else { startupTimeout = seconds }
            index += 2
        }
        guard command != "capture" || windowID != nil else {
            throw AgentFailure(.invalidArguments, "Usage: vishot capture --window-id <id>")
        }
        let executable = try executableURL()
        let app = try AgentEndpoint.containingApp(executableURL: executable)
        let serviceResponse = try AgentClient(endpoint: AgentEndpoint(appURL: app)).perform(
            AgentRequest(command: command, windowID: windowID),
            startupTimeout: startupTimeout, requestTimeout: requestTimeout, launch: launchApp)
        if let image = serviceResponse.image {
            response = .saved(try AgentCaptureOutput.save(image, in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        } else { response = serviceResponse }
    } catch let error as AgentFailure {
        response = .failure(error)
    } catch {
        response = .failure(AgentFailure(.serviceFailure, "The Vishot service request failed."))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        let data = try encoder.encode(response)
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    } catch { return 6 }
    return response.error?.exitStatus ?? 0
}

// Keep the main run loop available for Launch Services without activating a CLI app.
DispatchQueue.global(qos: .userInitiated).async { exit(run()) }
dispatchMain()
