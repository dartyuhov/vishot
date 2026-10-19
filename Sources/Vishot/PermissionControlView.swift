import AppKit

/// Shared native setup and Settings controls, away from picker rendering.
final class PermissionControlView: NSStackView {
    private var control: PermissionControl
    private let availability = NSTextField(labelWithString: "")
    private let openingError = NSTextField(wrappingLabelWithString: "")
    var onLayoutChange: (() -> Void)?

    init(permission: CapturePermission) {
        control = PermissionControl(permission: permission)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        let title = NSTextField(labelWithString: "\(permission.title) — \(permission.requirement)")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        availability.font = .systemFont(ofSize: 12)
        let enable = NSButton(title: "Enable…", target: self, action: #selector(enablePermission))
        enable.bezelStyle = .rounded
        enable.setAccessibilityLabel("Enable \(permission.title)")
        enable.setAccessibilityHelp("Opens System Settings. Enable Vishot there, then return to check access.")
        let row = NSStackView(views: [availability, NSView(), enable])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let explanation = label(permission.explanation)
        let instructions = label(permission.instructions)
        openingError.font = .systemFont(ofSize: 12)
        openingError.textColor = .labelColor
        openingError.isSelectable = true
        for view in [title, row, explanation, instructions, openingError] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        availability.stringValue = control.isAllowed ? "Allowed" : "Not Allowed"
        availability.setAccessibilityLabel("\(control.permission.title): \(availability.stringValue)")
        openingError.stringValue = control.openingError ?? ""
        openingError.isHidden = control.openingError == nil
    }

    @objc private func enablePermission() {
        control.enable()
        update()
        onLayoutChange?()
    }
}
