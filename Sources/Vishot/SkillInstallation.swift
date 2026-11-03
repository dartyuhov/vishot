import AppKit

/// Optional external installer text, shared by setup and Settings. No execution.
enum SkillInstallation {
    static let command = "npx skills add dartyuhov/vishot --skill vishot-capture"
}

/// Create a separate instance for each host; availability is independent of CLI
/// installation, permissions, and setup completion. Its only action copies text.
final class SkillInstallationView: NSStackView {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        identifier = NSUserInterfaceItemIdentifier("skill-installation")

        let title = NSTextField(labelWithString: "Agent skill — Optional")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let explanation = NSTextField(wrappingLabelWithString:
            "Teach your coding agent to discover windows, capture an exact window, and read the saved image.")
        let command = NSTextField(wrappingLabelWithString: SkillInstallation.command)
        command.identifier = NSUserInterfaceItemIdentifier("skill-install-command")
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        command.isSelectable = true
        command.setAccessibilityLabel("Optional agent skill installation command")
        let requirements = NSTextField(wrappingLabelWithString:
            "Run this yourself in a terminal from your project. The external Vercel skills installer requires Node.js 22.20 or newer, npm/npx, and network access. Choose your agents in the installer. The Vishot CLI needs none of these runtimes.")
        let policy = NSTextField(wrappingLabelWithString:
            "Vishot only copies this command. It does not run the installer, install Node/npm, choose agents, or copy skills into agent folders.")
        let copy = NSButton(title: "Copy Skill Install Command", target: self, action: #selector(copyCommand))
        copy.bezelStyle = .rounded
        copy.identifier = NSUserInterfaceItemIdentifier("copy-skill-install-command")
        copy.setAccessibilityHelp("Copies a command for you to review and run. Does not install anything.")

        for label in [explanation, requirements, policy] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        for view in [title, explanation, command, requirements, policy, copy] {
            addArrangedSubview(view)
            if let field = view as? NSTextField {
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyCommand() {
        pasteboard.clearContents()
        pasteboard.setString(SkillInstallation.command, forType: .string)
    }
}
