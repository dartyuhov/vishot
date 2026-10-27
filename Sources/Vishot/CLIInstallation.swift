import Foundation

/// Shared by Settings and optional first-time setup. Never replaces an existing item.
struct CLIInstallation {
    let bundleURL: URL
    let homeURL: URL
    let environment: [String: String]
    private let files = FileManager.default

    init(bundleURL: URL = Bundle.main.bundleURL,
         homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.bundleURL = bundleURL
        self.homeURL = homeURL
        self.environment = environment
    }

    var executableURL: URL { bundleURL.appendingPathComponent("Contents/Helpers/vishot") }
    var directoryURL: URL { homeURL.appendingPathComponent(".local/bin") }
    var linkURL: URL { directoryURL.appendingPathComponent("vishot") }

    enum Shell: String, CaseIterable {
        case zsh, bash, fish

        var command: String {
            switch self {
            case .zsh, .bash: return "export PATH=\"$HOME/.local/bin:$PATH\""
            case .fish: return "fish_add_path --universal --move --prepend \"$HOME/.local/bin\""
            }
        }

        var instructions: String {
            switch self {
            case .zsh: return "Run in zsh for this session. To keep it, add the same line to ~/.zshrc yourself."
            case .bash: return "Run in bash for this session. To keep it for login terminals, add the same line to ~/.bash_profile yourself (or ~/.bashrc for non-login shells)."
            case .fish: return "Install the CLI first so ~/.local/bin exists. Run in fish; this also applies to future fish sessions."
            }
        }
    }

    var suggestedShell: Shell {
        Shell(rawValue: (environment["SHELL"] ?? "").split(separator: "/").last.map(String.init) ?? "") ?? .zsh
    }

    var pathFeedback: String {
        let prefix: String
        if let path = environment["PATH"] {
            let contains = path.split(separator: ":", omittingEmptySubsequences: false).contains {
                $0.hasPrefix("/") && URL(fileURLWithPath: String($0)).standardizedFileURL.path == directoryURL.standardizedFileURL.path
            }
            prefix = "The app’s PATH snapshot \(contains ? "includes" : "does not include") ~/.local/bin."
        } else {
            prefix = "The app’s PATH snapshot is unavailable."
        }
        return prefix + " Vishot cannot verify your terminal or agent PATH. In that environment, run command -v vishot and vishot --version. If needed, choose your shell below and run the PATH command, then restart the agent so it inherits the change."
    }

    enum Status: Equatable {
        case notInstalled, installed, conflict, unavailable, failure(String)
    }

    func status() -> Status {
        do {
            let attributes = try files.attributesOfItem(atPath: linkURL.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try files.destinationOfSymbolicLink(atPath: linkURL.path)
                let target = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: directoryURL.path, isDirectory: true)).standardizedFileURL
                guard target.path == executableURL.standardizedFileURL.path else { return .conflict }
                return helperAvailable ? .installed : .unavailable
            }
            return .conflict
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return helperAvailable ? .notInstalled : .unavailable
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private var helperAvailable: Bool {
        var directory: ObjCBool = false
        return bundleURL.pathExtension == "app"
            && files.fileExists(atPath: executableURL.path, isDirectory: &directory)
            && !directory.boolValue && files.isExecutableFile(atPath: executableURL.path)
    }

    @discardableResult func install() -> Status {
        let current = status()
        guard current == .notInstalled else { return current }
        do {
            try files.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            // Creation fails atomically if another process creates a destination first.
            try files.createSymbolicLink(at: linkURL, withDestinationURL: executableURL)
            return status()
        } catch {
            let current = status()
            if current == .installed || current == .conflict { return current }
            return .failure(error.localizedDescription)
        }
    }
}
