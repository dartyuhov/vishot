import AppKit
import VishotAgent
import VishotConfiguration

/// Owns command interpretation and execution. Local annotation never reaches the capture client.
public enum CLIExecution {
    /// Call on a worker queue with the main run loop available for bounded Launch Services work.
    public static func execute(_ arguments: [String], executableURL: () throws -> URL,
                               workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                               configurationURL: URL = AppSettings.defaultURL) -> CLIResult {
        do {
            func containingApp() throws -> URL {
                let executable: URL
                do { executable = try executableURL() }
                catch { throw AgentFailure(.startupFailed, "Could not resolve the running Vishot CLI executable.") }
                return try AgentEndpoint.containingApp(executableURL: executable)
            }
            if arguments.first == "annotate" {
                return CLIResult(response: AnnotationCommand.execute(Array(arguments.dropFirst()), workspace: workspace,
                    resourceDirectory: { try containingApp().appendingPathComponent("Contents/Resources", isDirectory: true) },
                    styleSnapshot: { try AnnotationCommand.annotationStyleSnapshot(url: configurationURL) }))
            }
            if arguments == ["--version"] {
                let app = try containingApp()
                guard let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                    throw AgentFailure(.startupFailed, "The containing app has no release version.")
                }
                return try CLIResult(version: version)
            }
            let options = try CaptureArguments(arguments)
            let app = try containingApp()
            let response = try AgentClient(endpoint: AgentEndpoint(appURL: app)).perform(
                AgentRequest(command: options.command, windowID: options.windowID),
                startupTimeout: options.startupTimeout, requestTimeout: options.requestTimeout, launch: launchApp)
            if let image = response.image {
                return CLIResult(response: .saved(try AgentCaptureOutput.save(image, in: workspace)))
            }
            return CLIResult(response: response)
        } catch let failure as AgentFailure {
            return CLIResult(response: .failure(failure))
        } catch {
            return CLIResult(response: .failure(AgentFailure(.serviceFailure, "The Vishot service request failed.")))
        }
    }
}

private struct CaptureArguments {
    let command: String
    var windowID: UInt32?
    var startupTimeout: TimeInterval = 5
    var requestTimeout: TimeInterval = 5

    init(_ arguments: [String]) throws {
        guard let command = arguments.first, ["windows", "capture"].contains(command) else {
            throw AgentFailure(.invalidArguments, "Usage: vishot windows | vishot capture --window-id <id> [--startup-timeout <seconds>] [--timeout <seconds>]")
        }
        self.command = command
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
    }
}

/// Launch Services needs the main run loop, while its caller waits only within the startup budget.
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
