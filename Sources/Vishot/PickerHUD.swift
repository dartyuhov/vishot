import AppKit

/// The picker's rendered HUD and hover boundary, in panel-local Cocoa coordinates.
final class PickerHUD {
    static let elementUnavailableReason = "Element selection needs Accessibility. Enable it in Vishot Settings."

    static func elementsKey(accessibilityAvailable: Bool) -> HUDKey {
        HUDKey("f", action: "elements", unavailableReason: accessibilityAvailable ? nil : elementUnavailableReason)
    }

    let root = CALayer()
    private let row = CALayer()
    private let status: CATextLayer
    private let scale: CGFloat
    private var content: (name: String, keys: [HUDKey]) = ("", [])
    private var entries: [(key: HUDKey, layer: CALayer)] = []
    private var rowSize = CGSize.zero
    private var style: HUDStyle
    private struct PreparedRow {
        let content: HUDKeyRow
        let layer: CALayer
        let entries: [(key: HUDKey, layer: CALayer)]
        let size: CGSize
    }
    private struct HUDKeyRow: Equatable {
        let name: String
        let keys: [HUDKey]
    }
    private var prepared: [PreparedRow] = []

    init(scale: CGFloat, style: HUDStyle = ThemeCatalog.pixel.hud) {
        self.scale = scale
        self.style = style
        status = HUD.makeStatus(scale: scale, style: style)
        HUD.stylePanel(root, style: style)
        root.isHidden = true
        row.masksToBounds = true
        root.addSublayer(row)
        root.addSublayer(status)
    }

    func prepare(style: HUDStyle, modes: [(name: String, keys: [HUDKey])]) {
        self.style = style
        HUD.stylePanel(root, style: style)
        HUD.configure(status, font: style.textFont, color: style.muted, scale: scale)
        prepared.removeAll()
        row.sublayers?.forEach { $0.removeFromSuperlayer() }
        for mode in modes {
            layOutRow(name: mode.name, keys: mode.keys)
            let layer = CALayer()
            for child in row.sublayers ?? [] { child.removeFromSuperlayer(); layer.addSublayer(child) }
            prepared.append(PreparedRow(content: HUDKeyRow(name: mode.name, keys: mode.keys),
                layer: layer, entries: entries, size: rowSize))
        }
        content = ("", [])
    }

    func show(name: String, keys: [HUDKey], status message: String, size: CGSize, visible: Bool) {
        root.isHidden = !visible
        guard visible else { return }
        if content.name != name || content.keys != keys {
            row.sublayers?.forEach { $0.removeFromSuperlayer() }
            if let cached = prepared.first(where: { $0.content == HUDKeyRow(name: name, keys: keys) }) {
                row.addSublayer(cached.layer)
                entries = cached.entries
                rowSize = cached.size
            } else {
                layOutRow(name: name, keys: keys)
            }
            content = (name, keys)
        }
        let maxWidth = max(0, size.width - 2 * style.padding.width)
        let statusSize = message.isEmpty ? .zero : HUD.textSize(message, font: style.textFont)
        let width = min(max(rowSize.width, statusSize.width), maxWidth)
        let textHeight = message.isEmpty ? 0 : ceil((message as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
             attributes: [.font: style.textFont]).height)
        let statusHeight = message.isEmpty ? 0 : textHeight + style.lineGap
        root.frame = CGRect(x: ((size.width - width) / 2 - style.padding.width).rounded(), y: 24,
                            width: width + 2 * style.padding.width,
                            height: rowSize.height + statusHeight + 2 * style.padding.height)
        root.shadowPath = style.panel.path(in: root.bounds)
        // Keep the keys still when hover feedback appears; grow upward instead.
        let rowWidth = min(rowSize.width, maxWidth)
        row.frame = CGRect(x: ((size.width - rowWidth) / 2).rounded() - root.frame.minX, y: style.padding.height,
                           width: rowWidth, height: rowSize.height)
        status.isHidden = message.isEmpty
        status.isWrapped = true
        status.frame = CGRect(x: style.padding.width, y: style.padding.height + rowSize.height + style.lineGap,
                              width: width, height: textHeight)
        status.string = message
    }

    func unavailableReason(at point: CGPoint) -> String? {
        guard !root.isHidden, root.frame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - root.frame.minX, y: point.y - root.frame.minY)
        let rowPoint = row.convert(local, from: root)
        guard row.bounds.contains(rowPoint) else { return nil }
        return entries.first { !$0.layer.isHidden && $0.layer.bounds.contains($0.layer.convert(rowPoint, from: row)) }?.key.unavailableReason
    }

    private func layOutRow(name: String, keys: [HUDKey]) {
        row.sublayers?.forEach { $0.removeFromSuperlayer() }
        entries = keys.map { ($0, HUD.makeEntry($0, scale: scale, style: style).layer) }
        let height = max(HUD.textSize(name, font: style.nameFont).height, entries.map(\.layer.frame.height).max() ?? 0)
        let nameLayer = HUD.makeName(name, rowHeight: height, scale: scale, style: style)
        row.addSublayer(nameLayer)
        var x = nameLayer.frame.width
        for (_, entry) in entries {
            x += style.entryGap
            entry.frame.origin = CGPoint(x: x, y: ((height - entry.frame.height) / 2).rounded())
            row.addSublayer(entry)
            x += entry.frame.width
        }
        rowSize = CGSize(width: x, height: height)
    }
}
