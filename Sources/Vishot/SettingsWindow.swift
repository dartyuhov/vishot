import AppKit

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let recorder = ShortcutRecorder(frame: .zero)
    private let watermark = NSButton(checkboxWithTitle: "Include vishot.dev watermark", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let statusHeading = NSTextField(labelWithString: "")
    private let statusSection = NSStackView()
    private let contentStack = NSStackView()
    func recordGlobalShortcut(_ shortcut: CaptureShortcut) -> Bool {
        guard window?.isKeyWindow == true, recorder.isRecording else { return false }
        recorder.accept(shortcut)
        return true
    }

    init(store: SettingsStore) {
        self.store = store
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Vishot Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.isRecordingShortcut = { [weak self] in self?.recorder.isRecording == true }
        recorder.onRecord = { [weak self] shortcut in self?.store.update(shortcut: shortcut) }
        recorder.onError = { [weak self] message in self?.showStatus("Shortcut Error", message: message, isError: true) }
        recorder.setAccessibilityLabel("Global capture shortcut")
        recorder.setAccessibilityHelp("Press to record a shortcut. Include Command or Control. Escape cancels.")
        watermark.target = self
        watermark.action = #selector(toggleWatermark)
        let path = NSTextField(wrappingLabelWithString: (store.url.path as NSString).abbreviatingWithTildeInPath)
        path.isSelectable = true
        path.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let open = NSButton(title: "Open File…", target: self, action: #selector(openFile))
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealFile))
        let buttons = NSStackView(views: [open, reveal])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 28).isActive = true
        recorder.font = .systemFont(ofSize: 13, weight: .medium)
        recorder.lineBreakMode = .byTruncatingTail
        let shortcutLabel = NSTextField(labelWithString: "Keyboard shortcut")
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [shortcutLabel, NSView(), recorder])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        statusHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        statusSection.orientation = .vertical
        statusSection.alignment = .leading
        statusSection.spacing = 6
        statusSection.addArrangedSubview(statusHeading)
        statusSection.addArrangedSubview(status)
        let stack = contentStack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        let logo = NSImageView()
        logo.image = NSImage(named: NSImage.Name("AppIcon")) ?? NSApp.applicationIconImage
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.setAccessibilityLabel("Vishot logo")
        logo.widthAnchor.constraint(equalToConstant: 48).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(labelWithString: "Vishot")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let header = NSStackView(views: [logo, name, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        let sections = [
            header,
            section("Capture", views: [row, help("Click the shortcut to record a new one. Include ⌘ or ⌃; Esc cancels.")]),
            separator(),
            section("Watermark", views: [watermark, help("Keep this on to help others discover Vishot.")]),
            separator(),
            section("Configuration", views: [path, buttons, help("File edits reload automatically. Changes are saved as you make them.")]),
            statusSection,
        ]
        for view in sections { stack.addArrangedSubview(view) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        window.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        for view in sections { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        path.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func help(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func section(_ title: String, views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func showStatus(_ heading: String, message: String, isError: Bool) {
        statusSection.isHidden = message.isEmpty
        statusHeading.stringValue = heading
        statusHeading.textColor = isError ? .systemRed : .labelColor
        status.stringValue = message
        status.textColor = .secondaryLabelColor
        resizeToContent()
    }

    private func resizeToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        // Grow for feedback, with scrolling for unusually long parser errors.
        let height = min(max(contentStack.fittingSize.height + 48, 390), 620)
        var frame = window.frame
        let desired = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 520, height: height))
        frame.origin.y += frame.height - desired.height
        frame.size = desired.size
        window.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) { recorder.cancel() }
    func windowDidResignKey(_ notification: Notification) { recorder.cancel() }

    func present() {
        store.reload()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let settings = store.configured ?? store.active
        recorder.shortcut = settings.shortcut
        recorder.toolTip = "\(settings.shortcut.display) — Click to record a new shortcut"
        watermark.state = settings.watermark ? .on : .off
        watermark.isEnabled = store.configured != nil
        recorder.isEnabled = store.configured != nil
        if let error = store.error {
            showStatus("Configuration Error", message: "\(error)\nActive: \(store.active.shortcut.display); watermark \(store.active.watermark ? "on" : "off").", isError: true)
        } else if store.isSessionActive && store.configured != store.active {
            showStatus("Changes Pending", message: "Changes apply after this capture/editor session. Active: \(store.active.shortcut.display); watermark \(store.active.watermark ? "on" : "off").", isError: false)
        } else {
            showStatus("", message: "", isError: false)
        }
    }

    @objc private func toggleWatermark() { store.update(watermark: watermark.state == .on) }
    @objc private func openFile() {
        if !NSWorkspace.shared.open(store.url) { showStatus("Couldn’t Open File", message: "No app is configured to open TOML files. Use Reveal in Finder to choose an editor.", isError: true) }
    }
    @objc private func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
}

/// Accessory apps have no application menu supplying the standard Close command.
private final class SettingsPanel: NSWindow {
    var isRecordingShortcut: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecordingShortcut?() != true,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ShortcutRecorder: NSButton {
    var shortcut = CaptureShortcut.defaults { didSet { if !recording { title = shortcut.display } } }
    var onRecord: ((CaptureShortcut) -> Void)?
    var onError: ((String) -> Void)?
    private var recording = false
    var isRecording: Bool { recording }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(record)
        bezelStyle = .rounded
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func record() {
        recording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        cancel()
        return super.resignFirstResponder()
    }

    func cancel() {
        recording = false
        title = shortcut.display
    }

    func accept(_ next: CaptureShortcut) {
        recording = false
        onRecord?(next)
        title = shortcut.display
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            if event.keyCode == 49 || event.keyCode == 36 { record() } else { super.keyDown(with: event) }
            return
        }
        let commandOrControl = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if event.keyCode == 53 && !commandOrControl { _ = resignFirstResponder(); return }
        if event.keyCode == 48 && !commandOrControl {
            _ = resignFirstResponder()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        guard let key = CaptureShortcut.keys.first(where: { $0.1 == Int(event.keyCode) })?.0 else {
            onError?("This physical key is not supported."); return
        }
        let flags = event.modifierFlags
        let modifiers = [("command", NSEvent.ModifierFlags.command), ("control", .control), ("option", .option), ("shift", .shift)]
            .filter { flags.contains($0.1) }.map(\.0)
        do {
            let next = try CaptureShortcut(key: key, modifiers: modifiers).validated()
            accept(next)
        } catch { onError?(error.localizedDescription) }
    }
}
