import AppKit
import VishotRendering

final class SetupWindow: NSWindowController, NSWindowDelegate {
    private let flow: SetupFlow
    private let shortcut: () -> String
    private let capture: () -> Void
    private let checklist = NSStackView()
    private let guide = NSStackView()
    private let commandLine = NSStackView()
    private let cliControls: CLIInstallationView
    private let skillInstallation: SkillInstallationView
    private let skipButton = NSButton(title: "Skip for now", target: nil, action: nil)
    private let guideButton = NSButton(title: "Continue to guide", target: nil, action: nil)
    private let permissions = CapturePermission.allCases.map { PermissionControlView(permission: $0) }
    private let shortcutLabel = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(labelWithString: "Welcome to Vishot")
    private let subtitle = NSTextField(labelWithString: "Choose access for your screenshots.")
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let stepLabel = NSTextField(labelWithString: "")
    private let firstButton = NSButton(title: "Take a screenshot", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let scroll = NSScrollView()
    private var activationObserver: NSObjectProtocol?
    private var captureHandoffObserver: NSObjectProtocol?

    init(flow: SetupFlow, shortcut: @escaping () -> String, capture: @escaping () -> Void,
         cliInstallation: CLIInstallation = CLIInstallation(), skillPasteboard: NSPasteboard = .general) {
        self.flow = flow
        self.shortcut = shortcut
        self.capture = capture
        cliControls = CLIInstallationView(installation: cliInstallation)
        skillInstallation = SkillInstallationView(pasteboard: skillPasteboard)
        let window = SetupPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 510),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Vishot"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        configure(checklist)
        configure(guide)
        configure(commandLine)
        commandLine.addArrangedSubview(help("This step is optional. Skip it to keep taking screenshots normally; you can install later in Settings → Agent CLI."))
        commandLine.addArrangedSubview(cliControls)
        commandLine.addArrangedSubview(skillInstallation)
        cliControls.onLayoutChange = { [weak self] in self?.window?.contentView?.layoutSubtreeIfNeeded() }
        let logo = NSImageView()
        logo.image = NSImage(named: NSImage.Name("AppIcon")) ?? NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Vishot logo")
        logo.widthAnchor.constraint(equalToConstant: 64).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 64).isActive = true
        heading.font = Fonts.pixel()
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let headingText = NSStackView(views: [heading, subtitle])
        configure(headingText)
        headingText.spacing = 8
        let header = NSStackView(views: [logo, headingText, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        for permission in permissions {
            checklist.addArrangedSubview(permission)
            permission.onLayoutChange = { [weak self] in self?.refresh() }
        }
        continueButton.target = self
        continueButton.action = #selector(continueSetup)
        continueButton.keyEquivalent = "\r"
        continueButton.bezelColor = .controlColor

        shortcutLabel.font = Fonts.mono(24, bold: true)
        shortcutLabel.alignment = .left
        let shortcutCaption = help("Start a capture")
        let shortcutCard = NSStackView(views: [shortcutCaption, NSView(), shortcutLabel])
        shortcutCard.orientation = .horizontal
        shortcutCard.alignment = .centerY
        shortcutCard.spacing = 16
        shortcutCard.heightAnchor.constraint(equalToConstant: 64).isActive = true
        guide.addArrangedSubview(shortcutCard)
        let divider = NSBox()
        divider.boxType = .separator
        guide.addArrangedSubview(divider)
        let keys = NSStackView(views: [
            shortcutRow("hjkl / ↑ ↓ ← →", action: "Select Window"),
            shortcutRow("⇧ G", action: "Select Whole Screen"),
            shortcutRow("y / ↵", action: "Copy"),
            shortcutRow("e / ⇧ ↵", action: "Edit"),
        ])
        configure(keys)
        keys.spacing = 16
        for row in keys.arrangedSubviews { row.widthAnchor.constraint(equalTo: keys.widthAnchor).isActive = true }
        guide.addArrangedSubview(keys)
        firstButton.target = self
        firstButton.action = #selector(firstCapture)
        doneButton.target = self
        doneButton.action = #selector(finish)
        backButton.target = self
        backButton.action = #selector(goBack)
        for button in [skipButton, guideButton] {
            button.target = self
            button.action = #selector(showGuide)
        }
        for button in [continueButton, firstButton, doneButton, backButton, skipButton, guideButton] {
            button.bezelStyle = .rounded
            button.bezelColor = .controlColor
        }
        let actions = NSStackView(views: [backButton, NSView(), continueButton, skipButton, guideButton, doneButton, firstButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        stepLabel.font = Fonts.mono(11)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [checklist, commandLine, guide])
        configure(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SetupDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.addSubview(header)
        content.addSubview(stepLabel)
        content.addSubview(scroll)
        content.addSubview(actions)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.heightAnchor.constraint(equalToConstant: 64),
            stepLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stepLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -20),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            actions.heightAnchor.constraint(equalToConstant: 32),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        for section in [checklist, commandLine, guide] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            for view in section.arrangedSubviews { view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refresh()
        }
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let captureHandoffObserver { NotificationCenter.default.removeObserver(captureHandoffObserver) }
    }

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

    private func shortcutRow(_ keys: String, action: String) -> NSStackView {
        let keycap = NSTextField(labelWithString: keys)
        keycap.font = Fonts.mono(13)
        keycap.alignment = .left
        keycap.widthAnchor.constraint(equalToConstant: 200).isActive = true
        keycap.isBezeled = true
        keycap.bezelStyle = .squareBezel
        keycap.drawsBackground = true
        keycap.backgroundColor = .controlBackgroundColor
        let label = NSTextField(labelWithString: action)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let row = NSStackView(views: [keycap, label, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 24
        return row
    }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        flow.refresh()
        permissions.forEach { $0.refresh() }
        cliControls.refresh()
        continueButton.isEnabled = flow.screenRecordingAllowed
        continueButton.title = flow.accessibilityAllowed ? "Continue" : "Continue without Accessibility"
        shortcutLabel.stringValue = shortcut()
        switch flow.step {
        case .permissions:
            heading.stringValue = "Welcome to Vishot"
            subtitle.stringValue = "Choose access for your screenshots."
            stepLabel.stringValue = "STEP 1 OF 3 · PERMISSIONS"
        case .commandLine:
            heading.stringValue = "CLI for coding agents"
            subtitle.stringValue = "Optional tools for window discovery and capture."
            stepLabel.stringValue = "STEP 2 OF 3 · OPTIONAL CLI"
        case .guide:
            heading.stringValue = "Ready to capture"
            subtitle.stringValue = "Your keyboard-first screenshot guide."
            stepLabel.stringValue = "STEP 3 OF 3 · QUICK GUIDE"
        }
        continueButton.isHidden = flow.step != .permissions
        backButton.isHidden = flow.step == .permissions
        skipButton.isHidden = flow.step != .commandLine
        guideButton.isHidden = flow.step != .commandLine
        doneButton.isHidden = !flow.isShowingGuide
        firstButton.isHidden = !flow.isShowingGuide
        continueButton.keyEquivalent = flow.step == .permissions ? "\r" : ""
        guideButton.keyEquivalent = flow.step == .commandLine ? "\r" : ""
        firstButton.keyEquivalent = flow.isShowingGuide ? "\r" : ""
        checklist.isHidden = flow.step != .permissions
        commandLine.isHidden = flow.step != .commandLine
        guide.isHidden = !flow.isShowingGuide
        window?.recalculateKeyViewLoop()
    }

    @objc private func continueSetup() {
        flow.continueToCLI(withoutAccessibility: !flow.accessibilityAllowed)
        refresh()
        scroll.contentView.scroll(to: .zero)
        window?.selectNextKeyView(nil)
    }

    @objc private func goBack() {
        if flow.isShowingGuide { flow.continueToCLI() }
        else { flow.returnToChecklist() }
        refresh()
        scroll.contentView.scroll(to: .zero)
    }

    @objc private func showGuide() {
        flow.continueToGuide()
        refresh()
        scroll.contentView.scroll(to: .zero)
        window?.selectNextKeyView(nil)
    }

    @objc private func finish() {
        if flow.needsSetup { flow.finish(dismiss: { self.window?.orderOut(nil) }) }
        else { window?.orderOut(nil) }
        refresh()
    }
    @objc private func firstCapture() { takeFirstScreenshot() }
    func takeFirstScreenshot() {
        guard captureHandoffObserver == nil else { return }
        flow.refresh()
        guard flow.isShowingGuide, flow.screenRecordingAllowed else { refresh(); return }
        if flow.needsSetup { flow.finish(dismiss: {}) }
        refresh()
        window?.orderOut(nil)
        // Return focus to the underlying app before our nonactivating picker
        // panel takes it. Otherwise ordering out the last active setup window
        // can leave a pending key-window transition that cancels the picker.
        if NSApp.isActive {
            captureHandoffObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if let observer = self.captureHandoffObserver { NotificationCenter.default.removeObserver(observer) }
                self.captureHandoffObserver = nil
                DispatchQueue.main.async { [weak self] in self?.capture() }
            }
            NSApp.deactivate()
        } else {
            DispatchQueue.main.async { [weak self] in self?.capture() }
        }
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
                  readAccess: { (CapturePermission.screenRecording.readAccess(), CapturePermission.accessibility.readAccess()) })
    }
}
