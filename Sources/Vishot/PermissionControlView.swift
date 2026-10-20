import AppKit

/// Shared native setup and Settings controls, away from picker rendering.
final class PermissionControlView: NSStackView {
    private var control: PermissionControl
    private let availability = NSTextField(labelWithString: "✓ Enabled")
    private let enable = NSButton(title: "Enable…", target: nil, action: nil)
    private let instructions = NSTextField(wrappingLabelWithString: "")
    private let openingError = NSTextField(wrappingLabelWithString: "")
    private var hasOpenedSettings = false
    var onLayoutChange: (() -> Void)?

    init(permission: CapturePermission, readAccess: (() -> Bool)? = nil) {
        control = PermissionControl(permission: permission, readAccess: readAccess)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        wantsLayer = true
        updateSurface()

        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let requirement = NSTextField(labelWithString: permission.requirement)
        requirement.font = .systemFont(ofSize: 11, weight: .medium)
        requirement.textColor = .secondaryLabelColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: permission == .screenRecording ? "viewfinder" : "accessibility", accessibilityDescription: nil)
        icon.setAccessibilityElement(false)
        icon.contentTintColor = Palette.accent
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        availability.font = .systemFont(ofSize: 12)
        availability.textColor = .systemGreen
        availability.setContentCompressionResistancePriority(.required, for: .horizontal)
        enable.target = self
        enable.action = #selector(enablePermission)
        enable.bezelStyle = .rounded
        enable.setAccessibilityLabel("Enable \(permission.title)")
        enable.setAccessibilityHelp("Opens System Settings. Enable Vishot there, then return to check access.")
        let labels = NSStackView(views: [title, requirement])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let row = NSStackView(views: [icon, labels, NSView(), availability, enable])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let explanation = label(permission.explanation)
        instructions.stringValue = permission.instructions
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        instructions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openingError.font = .systemFont(ofSize: 12)
        openingError.textColor = .labelColor
        openingError.isSelectable = true
        for view in [row, explanation, instructions, openingError] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

    func refresh() {
        control.refresh()
        update()
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func update() {
        availability.isHidden = !control.isAllowed
        enable.isHidden = control.isAllowed
        enable.isEnabled = !control.isAllowed
        availability.setAccessibilityLabel("\(control.permission.title): Enabled")
        instructions.isHidden = control.isAllowed || !hasOpenedSettings || control.openingError != nil
        openingError.stringValue = control.openingError ?? ""
        openingError.isHidden = control.openingError == nil
    }

    @objc private func enablePermission() {
        hasOpenedSettings = true
        control.enable()
        update()
        onLayoutChange?()
    }
}
