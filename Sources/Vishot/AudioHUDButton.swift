import AppKit

/// Native button semantics and tracking, with theme-owned icon drawing. No audio discovery.
final class AudioHUDButton: NSButton {
    let control: PickerHUD.AudioControl
    private var theme = ThemeCatalog.pixel
    private var audioEnabled = false

    init(control: PickerHUD.AudioControl) {
        self.control = control
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        setAccessibilityLabel(control.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(theme: ResolvedTheme, enabled: Bool) {
        self.theme = theme
        audioEnabled = enabled
        let state = enabled ? "on" : "off"
        toolTip = "\(control.title) \(state) — click to turn \(enabled ? "off" : "on")"
        setAccessibilityValue(enabled ? "On" : "Off")
        setAccessibilityHelp("Turn \(control.title.lowercased()) \(enabled ? "off" : "on")")
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pixel = theme.hud.panel.cornerRadius == 0
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let plate = NSBezierPath(roundedRect: rect, xRadius: pixel ? 0 : 6, yRadius: pixel ? 0 : 6)
        (isHighlighted ? theme.editor.active : theme.hud.keycap.face).setFill()
        plate.fill()
        (window?.firstResponder === self ? theme.picker.accent : theme.hud.keycap.edge).setStroke()
        plate.lineWidth = pixel ? 2 : 1
        plate.stroke()
        let color = isHighlighted ? theme.editor.activeText : theme.hud.text
        if pixel {
            drawPixelIcon(color: color)
        } else {
            let name = control == .microphone ? (audioEnabled ? "mic" : "mic.slash") : (audioEnabled ? "speaker.wave.2" : "speaker.slash")
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
            image?.isTemplate = true
            contentTintColor = color
            // Draw the template using an explicit color, independent of system appearance.
            let icon = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { rect in
                image?.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            icon.draw(in: CGRect(x: (bounds.width - 22) / 2, y: (bounds.height - 22) / 2, width: 22, height: 22))
        }
    }

    private func drawPixelIcon(color: NSColor) {
        let mic = ["00011100000", "00111110000", "00111110000", "00111110000", "10111110100", "10111110100", "10011100100", "01000001000", "00111110000", "00001000000", "00111110000"]
        let speaker = ["00001000000", "00011001000", "00111000100", "11111010100", "11111010100", "11111010100", "11111010100", "11111010100", "00111000100", "00011001000", "00001000000"]
        let rows = control == .microphone ? mic : speaker
        let origin = CGPoint(x: floor((bounds.width - 22) / 2), y: floor((bounds.height - 22) / 2))
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
        // Bitmap rows are top-down; native button drawing may already be flipped.
        func rowY(_ row: Int) -> CGFloat { origin.y + CGFloat((isFlipped ? row : 10 - row) * 2) }
        color.setFill()
        for (y, row) in rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == "1" {
                CGRect(x: origin.x + CGFloat(x * 2), y: rowY(y), width: 2, height: 2).fill()
            }
        }
        if !audioEnabled {
            // Clear a one-cell channel so the stepped slash stays readable over the glyph.
            for step in 0..<11 {
                let cell = CGRect(x: origin.x + CGFloat(step * 2), y: rowY(step), width: 2, height: 2)
                (isHighlighted ? theme.editor.active : theme.hud.keycap.face).setFill()
                cell.insetBy(dx: -2, dy: 0).fill()
            }
            color.setFill()
            for step in 0..<11 {
                CGRect(x: origin.x + CGFloat(step * 2), y: rowY(step), width: 2, height: 2).fill()
            }
        }
    }
}
