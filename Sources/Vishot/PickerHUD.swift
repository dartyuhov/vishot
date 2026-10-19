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

    init(scale: CGFloat) {
        self.scale = scale
        status = HUD.makeStatus(scale: scale)
        HUD.stylePanel(root)
        root.isHidden = true
        row.masksToBounds = true
        root.addSublayer(row)
        root.addSublayer(status)
    }

    func show(name: String, keys: [HUDKey], status message: String, size: CGSize, visible: Bool) {
        root.isHidden = !visible
        guard visible else { return }
        if content.name != name || content.keys != keys {
            layOutRow(name: name, keys: keys)
            content = (name, keys)
        }
        let maxWidth = max(0, size.width - 2 * HUD.padding.width)
        let statusSize = message.isEmpty ? .zero : HUD.textSize(message, font: HUD.textFont)
        let width = min(max(rowSize.width, statusSize.width), maxWidth)
        let textHeight = message.isEmpty ? 0 : ceil((message as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: HUD.textFont]).height)
        let statusHeight = message.isEmpty ? 0 : textHeight + HUD.lineGap
        root.frame = CGRect(x: ((size.width - width) / 2 - HUD.padding.width).rounded(), y: 24,
                            width: width + 2 * HUD.padding.width,
                            height: rowSize.height + statusHeight + 2 * HUD.padding.height)
        root.shadowPath = CGPath(rect: root.bounds, transform: nil)
        // Keep the keys still when hover feedback appears; grow upward instead.
        let rowWidth = min(rowSize.width, maxWidth)
        row.frame = CGRect(x: ((size.width - rowWidth) / 2).rounded() - root.frame.minX, y: HUD.padding.height,
                           width: rowWidth, height: rowSize.height)
        status.isHidden = message.isEmpty
        status.isWrapped = true
        status.frame = CGRect(x: HUD.padding.width, y: HUD.padding.height + rowSize.height + HUD.lineGap,
                              width: width, height: textHeight)
        status.string = message
    }

    func unavailableReason(at point: CGPoint) -> String? {
        guard !root.isHidden, root.frame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - root.frame.minX, y: point.y - root.frame.minY)
        let rowPoint = row.convert(local, from: root)
        guard row.bounds.contains(rowPoint) else { return nil }
        return entries.first { !$0.layer.isHidden && $0.layer.frame.contains(rowPoint) }?.key.unavailableReason
    }

    private func layOutRow(name: String, keys: [HUDKey]) {
        row.sublayers?.forEach { $0.removeFromSuperlayer() }
        entries = keys.map { ($0, HUD.makeEntry($0, scale: scale).layer) }
        let height = max(HUD.textSize(name, font: HUD.nameFont).height, entries.map(\.layer.frame.height).max() ?? 0)
        let nameLayer = HUD.makeName(name, rowHeight: height, scale: scale)
        row.addSublayer(nameLayer)
        var x = nameLayer.frame.width
        for (_, entry) in entries {
            x += HUD.entryGap
            entry.frame.origin = CGPoint(x: x, y: ((height - entry.frame.height) / 2).rounded())
            row.addSublayer(entry)
            x += entry.frame.width
        }
        rowSize = CGSize(width: x, height: height)
    }
}
