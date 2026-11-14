import AppKit

/// Optional native permission card shared by onboarding and Settings.
final class MicrophonePermissionView: NSStackView {
    private let permission: MicrophonePermission
    private let openPage: (URL) -> Bool
    private let availability = NSTextField(labelWithString: "")
    private let enable = NSButton(title: "Allow Microphone…", target: nil, action: nil)
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let openingError = NSTextField(wrappingLabelWithString: "")
    private var request: UUID?
    var onLayoutChange: (() -> Void)?

    init(permission: MicrophonePermission = .shared,
         openPage: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.permission = permission
        self.openPage = openPage
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        wantsLayer = true
        updateSurface()
        let title = NSTextField(labelWithString: "Microphone")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let requirement = label("Optional · For video narration")
        let labels = NSStackView(views: [title, requirement])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        icon.setAccessibilityElement(false)
        icon.contentTintColor = Palette.accent
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        availability.font = .systemFont(ofSize: 12)
        enable.target = self
        enable.action = #selector(enablePermission)
        enable.bezelStyle = .rounded
        let row = NSStackView(views: [icon, labels, NSView(), enable])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let explanation = label("Prepare access for microphone audio in videos. Skip this for screenshots or video without a microphone; allowing access does not turn audio on.")
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        openingError.font = .systemFont(ofSize: 12)
        openingError.isSelectable = true
        for view in [row, explanation, availability, instructions, openingError] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let request { permission.cancel(request) } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func refresh() {
        let status = permission.refresh()
        enable.isHidden = status == .authorized
        enable.isEnabled = request == nil
        enable.title = status == .notDetermined ? "Allow Microphone…" : "Open System Settings…"
        enable.setAccessibilityLabel(status == .notDetermined ? "Allow Microphone" : "Open Microphone Settings")
        enable.setAccessibilityHelp(status == .notDetermined ? "Requests optional microphone permission from macOS." : "Opens Privacy & Security → Microphone. Return here to check access.")
        switch status {
        case .notDetermined:
            availability.stringValue = request == nil ? "Not requested" : "Waiting for microphone permission…"
            instructions.stringValue = ""
        case .authorized:
            availability.stringValue = "✓ Enabled"
            instructions.stringValue = ""
            openingError.stringValue = ""
        case .denied:
            availability.stringValue = "Denied"
            instructions.stringValue = "Open System Settings → Privacy & Security → Microphone, then enable Vishot. Return here to check access. If macOS asks you to quit and reopen Vishot, do so before checking again. You can continue without microphone audio."
        case .restricted:
            availability.stringValue = "Restricted"
            instructions.stringValue = "Microphone access is restricted by macOS policy. Check System Settings → Privacy & Security → Microphone or contact your administrator. You can continue without microphone audio."
        }
        availability.textColor = status == .authorized ? .systemGreen : .secondaryLabelColor
        availability.setAccessibilityLabel("Microphone: \(availability.stringValue)")
        instructions.isHidden = instructions.stringValue.isEmpty
        openingError.isHidden = openingError.stringValue.isEmpty
    }

    func cancelPendingRequest() {
        if let request { permission.cancel(request) }
        request = nil
        refresh()
    }

    @objc private func enablePermission() {
        guard request == nil else { return }
        switch permission.status {
        case .authorized: refresh()
        case .denied, .restricted:
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            openingError.stringValue = openPage(url) ? "" : "Couldn’t open System Settings. Open System Settings → Privacy & Security → Microphone manually."
            refresh()
            onLayoutChange?()
        case .notDetermined:
            openingError.stringValue = ""
            let origin = window
            request = permission.request { [weak self, weak origin] _ in
                guard let self else { return }
                self.request = nil
                self.refresh()
                self.onLayoutChange?()
                // Never reopen a closed window or steal focus from another app
                // or window after a delayed system response.
                if let origin, origin.isVisible, !self.isHiddenOrHasHiddenAncestor,
                   NSApp.isActive, NSApp.keyWindow == nil || NSApp.keyWindow === origin {
                    origin.makeKey()
                    if !self.enable.isHidden { origin.makeFirstResponder(self.enable) }
                    else { origin.selectNextKeyView(self.enable) }
                }
            }
            refresh()
            onLayoutChange?()
        }
    }
}
