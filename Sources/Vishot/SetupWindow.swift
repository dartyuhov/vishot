import AppKit
import ApplicationServices

final class SetupWindow: NSWindowController, NSWindowDelegate {
    private let flow: SetupFlow
    private let shortcut: () -> String
    private let capture: () -> Void
    private let checklist = NSStackView()
    private let guide = NSStackView()
    private let screenStatus = NSTextField(labelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(wrappingLabelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private var activationObserver: NSObjectProtocol?

    init(flow: SetupFlow, shortcut: @escaping () -> String, capture: @escaping () -> Void) {
        self.flow = flow
        self.shortcut = shortcut
        self.capture = capture
        let window = SetupPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Vishot"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        configure(checklist)
        configure(guide)
        let heading = NSTextField(labelWithString: "Welcome to Vishot")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        checklist.addArrangedSubview(heading)
        checklist.addArrangedSubview(help("Choose access for keyboard-first screenshots. Enable Vishot yourself in System Settings → Privacy & Security."))
        addPermission(to: checklist, heading: "Required · Screen Recording", status: screenStatus,
                      explanation: "Allows Vishot to capture screenshots of your windows and displays.",
                      action: #selector(enableScreenRecording))
        addPermission(to: checklist, heading: "Optional, recommended · Accessibility", status: accessibilityStatus,
                      explanation: "Temporarily brings keyboard-selected windows forward and lets you select UI elements. Without it, you can still select windows and capture screenshots.",
                      action: #selector(enableAccessibility))
        checklist.addArrangedSubview(help("If access still shows Not allowed after enabling it, quit and reopen Vishot. Setup will return until you finish."))
        continueButton.target = self
        continueButton.action = #selector(continueSetup)
        continueButton.keyEquivalent = "\r"
        checklist.addArrangedSubview(continueButton)

        let ready = NSTextField(labelWithString: "Ready to capture")
        ready.font = .systemFont(ofSize: 22, weight: .semibold)
        guide.addArrangedSubview(ready)
        shortcutLabel.font = .systemFont(ofSize: 17, weight: .medium)
        guide.addArrangedSubview(shortcutLabel)
        guide.addArrangedSubview(help("Select a window with hjkl or the arrow keys.\nPress Return to copy your screenshot.\nPress Shift–Return to edit before copying or saving."))
        guide.addArrangedSubview(help("Vishot stays in your menu bar. You can change your shortcut and permissions in Settings."))
        let first = NSButton(title: "Take your first screenshot", target: self, action: #selector(firstCapture))
        first.keyEquivalent = "\r"
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        let back = NSButton(title: "Back", target: self, action: #selector(backToChecklist))
        let actions = NSStackView(views: [back, NSView(), done, first])
        actions.orientation = .horizontal
        actions.spacing = 8
        guide.addArrangedSubview(actions)

        feedback.font = .systemFont(ofSize: 12)
        feedback.textColor = .secondaryLabelColor
        feedback.isSelectable = true
        let stack = NSStackView(views: [checklist, guide, feedback])
        configure(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SetupDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
        ])
        for section in [checklist, guide] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for view in section.arrangedSubviews { view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        }
        feedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refresh()
        }
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    private func configure(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
    }

    private func help(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func addPermission(to stack: NSStackView, heading: String, status: NSTextField,
                               explanation: String, action: Selector) {
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let enable = NSButton(title: "Enable…", target: self, action: action)
        enable.setAccessibilityLabel("Enable \(heading.contains("Screen Recording") ? "Screen Recording" : "Accessibility")")
        let row = NSStackView(views: [status, NSView(), enable])
        row.orientation = .horizontal
        let description = help(explanation)
        let section = NSStackView(views: [title, description, row])
        configure(section)
        section.spacing = 8
        for view in section.arrangedSubviews { view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        stack.addArrangedSubview(section)
    }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        flow.refresh()
        screenStatus.stringValue = flow.screenRecordingAllowed ? "Allowed" : "Not allowed"
        accessibilityStatus.stringValue = flow.accessibilityAllowed ? "Allowed" : "Not allowed"
        continueButton.isEnabled = flow.screenRecordingAllowed
        continueButton.title = flow.accessibilityAllowed ? "Continue" : "Continue without Accessibility"
        shortcutLabel.stringValue = "Press \(shortcut()) to start a capture."
        checklist.isHidden = flow.isShowingGuide
        guide.isHidden = !flow.isShowingGuide
        feedback.isHidden = feedback.stringValue.isEmpty
        window?.recalculateKeyViewLoop()
    }

    @objc private func continueSetup() {
        flow.continueToGuide(withoutAccessibility: !flow.accessibilityAllowed)
        refresh()
        window?.selectNextKeyView(nil)
    }

    @objc private func backToChecklist() {
        flow.returnToChecklist()
        refresh()
    }

    @objc private func finish() { complete(takeScreenshot: false) }
    @objc private func firstCapture() { complete(takeScreenshot: true) }
    private func complete(takeScreenshot: Bool) {
        flow.finish(dismiss: { self.window?.orderOut(nil) }, capture: takeScreenshot ? capture : nil)
        refresh()
    }

    @objc private func enableScreenRecording() { openPrivacyPage("Screen Recording", anchor: "Privacy_ScreenCapture") }
    @objc private func enableAccessibility() { openPrivacyPage("Accessibility", anchor: "Privacy_Accessibility") }

    private func openPrivacyPage(_ name: String, anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        let opened = NSWorkspace.shared.open(url)
        feedback.stringValue = (opened ? "" : "Couldn’t open System Settings. ") +
            "In System Settings → Privacy & Security → \(name), enable Vishot. Opening the page does not grant access."
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        flow.dismissIncomplete { NSApp.terminate(nil) }
    }
}

/// Accessory apps do not have the usual application menu's Close command.
private final class SetupPanel: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SetupDocumentView: NSView {
    override var isFlipped: Bool { true }
}

extension SetupFlow {
    static func live(defaults: UserDefaults = .standard) -> SetupFlow {
        SetupFlow(isComplete: { defaults.bool(forKey: "setupComplete") },
                  rememberCompletion: { defaults.set(true, forKey: "setupComplete") },
                  readAccess: { (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted()) })
    }
}
