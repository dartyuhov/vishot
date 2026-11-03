import AppKit

/// Optional installation controls, reusable by the setup guide.
final class CLIInstallationView: NSStackView {
    private let installation: CLIInstallation
    private let installButton = NSButton(title: "Install CLI", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let shell = NSPopUpButton(frame: .zero, pullsDown: false)
    private let command = NSTextField(wrappingLabelWithString: "")
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy PATH Command", target: nil, action: nil)
    private let pasteboard: NSPasteboard
    var onLayoutChange: (() -> Void)?

    init(installation: CLIInstallation = CLIInstallation(), pasteboard: NSPasteboard = .general) {
        self.installation = installation
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let caption = NSTextField(wrappingLabelWithString: "Optional: enable window discovery and capture for coding agents. Installs a link in ~/.local/bin; the CLI updates with this app.")
        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        installButton.target = self
        installButton.action = #selector(installCLI)
        installButton.bezelStyle = .rounded
        feedback.font = .systemFont(ofSize: 12)
        feedback.isSelectable = true
        let pathFeedback = NSTextField(wrappingLabelWithString: installation.pathFeedback)
        pathFeedback.font = .systemFont(ofSize: 12)
        pathFeedback.textColor = .secondaryLabelColor
        shell.addItems(withTitles: CLIInstallation.Shell.allCases.map(\.rawValue))
        shell.selectItem(withTitle: installation.suggestedShell.rawValue)
        shell.setAccessibilityLabel("Shell for PATH guidance")
        shell.target = self
        shell.action = #selector(changeShell)
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        copyButton.bezelStyle = .rounded
        let actions = NSStackView(views: [NSTextField(labelWithString: "Your shell"), shell, copyButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.isSelectable = true
        command.setAccessibilityLabel("PATH command")
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        for view in [caption, installButton, feedback, pathFeedback, actions, command, instructions] { addArrangedSubview(view) }
        for label in [caption, feedback, pathFeedback, command, instructions] {
            label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        changeShell()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() { show(installation.status()) }

    private func show(_ status: CLIInstallation.Status) {
        installButton.isEnabled = status == .notInstalled
        installButton.title = status == .installed ? "CLI Installed" : "Install CLI"
        feedback.textColor = .secondaryLabelColor
        switch status {
        case .notInstalled:
            feedback.stringValue = "Not installed. Destination: \(installation.linkURL.path)"
        case .installed:
            feedback.stringValue = "Installed: \(installation.linkURL.path) → \(installation.executableURL.path)"
        case .conflict:
            feedback.stringValue = "Installation conflict: \(installation.linkURL.path) already exists and was left untouched. Move or rename it yourself if you want to install Vishot here, then reopen Settings."
            feedback.textColor = .systemRed
        case .unavailable:
            feedback.stringValue = "Bundled CLI unavailable at \(installation.executableURL.path). Open an installed Vishot app that includes the CLI, then try again."
        case .failure(let message):
            feedback.stringValue = "Couldn’t install at \(installation.linkURL.path): \(message) Check the directory’s access permissions and try again."
            feedback.textColor = .systemRed
            installButton.isEnabled = true
        }
        onLayoutChange?()
    }

    @objc private func installCLI() { show(installation.install()) }

    @objc private func changeShell() {
        let selected = CLIInstallation.Shell.allCases[shell.indexOfSelectedItem]
        command.stringValue = selected.command
        instructions.stringValue = selected.instructions
        copyButton.title = "Copy PATH Command"
        onLayoutChange?()
    }

    @objc private func copyCommand() {
        pasteboard.clearContents()
        copyButton.title = pasteboard.setString(command.stringValue, forType: .string) ? "Copied" : "Copy Failed — Retry"
    }
}
