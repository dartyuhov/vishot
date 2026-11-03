import AppKit
import Carbon.HIToolbox

/// The picker's rendered HUD and hover boundary, in panel-local Cocoa coordinates.
final class PickerHUD {
    enum CaptureType: CaseIterable { case screenshot, video }
    enum Picker: String, CaseIterable { case window = "Window", element = "Element", hint = "Hint", screen = "Screen", region = "Region" }
    enum RegionState: CaseIterable { case empty, drawing, ready }
    struct Choice: Equatable {
        let picker: Picker
        let key: HUDKey
        let isActive: Bool
    }

    /// Presentation input from the picker; independent of recorder and permission discovery.
    struct Content: Equatable {
        enum TypeKeyResult { case unhandled, handled, unavailable }
        var captureType: CaptureType = .screenshot
        var picker: Picker = .window
        var accessibilityAvailable = true
        var historyAvailable = true
        var regionState: RegionState = .empty
        var isCountingDown = false
        /// Physical keys only; the caller keeps its target and region untouched.
        mutating func handleCaptureTypeKey(_ code: Int) -> TypeKeyResult {
            guard picker != .hint, !isCountingDown, code == kVK_ANSI_R || code == kVK_ANSI_S else { return .unhandled }
            if code == kVK_ANSI_R && !historyAvailable { return .unavailable }
            captureType = code == kVK_ANSI_R ? .video : .screenshot
            return .handled
        }
        var captureName: String { captureType == .video ? "Video" : "Screenshot" }
        var typeSwitch: HUDKey? {
            guard picker != .hint, !isCountingDown else { return nil }
            return captureType == .video ? HUDKey("s", action: "Switch to screenshot") :
                HUDKey("r", action: "Switch to video", unavailableReason: historyAvailable ? nil : PickerHUD.historyUnavailableReason)
        }
        var choices: [Choice] {
            guard !isCountingDown else { return [] }
            return [Picker.window, .element, .screen, .region].map { choice in
                let key: HUDKey
                switch choice {
                case .element:
                    let reason = accessibilityAvailable ? nil : PickerHUD.elementUnavailableReason
                    key = HUDKey(action: "Element", unavailableReason: reason)
                default: key = HUDKey(action: choice.rawValue)
                }
                return Choice(picker: choice, key: key, isActive: choice == (picker == .hint ? .element : picker))
            }
        }
        var navigation: [HUDKey] {
            guard !isCountingDown else { return [] }
            switch picker {
            case .window, .element: return [PickerHUD.elementsKey(accessibilityAvailable: accessibilityAvailable), HUDKey("G", action: "Whole screen"), HUDKey("v", action: "Select region")]
            case .screen: return [HUDKey("v", action: "Select region")]
            case .hint: return [HUDKey(action: "Type a hint"), HUDKey("⌫", action: "Undo")]
            case .region:
                return [HUDKey("v", action: regionState == .drawing ? "Finish region" : regionState == .ready ? "Redraw" : "Start region")]
            }
        }
        var actions: [HUDKey] {
            if isCountingDown { return [HUDKey("esc", action: "Cancel")] }
            let canCapture = picker != .hint && (picker != .region || regionState == .ready)
            let capture: [HUDKey] = !canCapture ? [] : captureType == .video ?
                [HUDKey("↵", action: "Record", unavailableReason: historyAvailable ? nil : PickerHUD.historyUnavailableReason)] :
                [HUDKey("↵", action: "Copy"), HUDKey("e", action: "Edit")]
            return capture + [HUDKey("esc", action: picker == .window ? "Cancel" :
                picker == .region && regionState == .drawing ? "Cancel region" : "Back")] +
                (picker == .region ? [HUDKey("q", action: "Cancel")] : [])
        }
    }

    static let elementUnavailableReason = "Element selection needs Accessibility. Enable it in Vishot Settings."
    static let historyUnavailableReason = "Video requires History. Enable retention in Vishot Settings."

    static func elementsKey(accessibilityAvailable: Bool) -> HUDKey {
        HUDKey("f", action: "Select elements", unavailableReason: accessibilityAvailable ? nil : elementUnavailableReason)
    }

    let root = CALayer()
    private let status: CATextLayer
    private let scale: CGFloat
    private var style: HUDStyle
    private var bottomInset: CGFloat = 24
    private let bands = [CALayer(), CALayer()]
    private let separators = [CALayer()]
    private struct Band: Equatable {
        var name = ""
        var keys: [HUDKey] = []
        var active: Int? = nil
        var actionsStart: Int? = nil
    }
    private struct PreparedBand {
        let content: Band
        let items: [(key: HUDKey?, layer: CALayer)]
    }
    private var prepared: [PreparedBand] = []
    private var visibleItems: [(key: HUDKey?, layer: CALayer)] = []
    private var layoutContent: Content?
    private var layoutWidth: CGFloat = 0
    private var contentHeight: CGFloat = 0

    init(scale: CGFloat, style: HUDStyle = ThemeCatalog.pixel.hud) {
        self.scale = scale
        self.style = style
        status = HUD.makeStatus(scale: scale, style: style)
        HUD.stylePanel(root, style: style)
        root.isHidden = true
        bands.forEach { root.addSublayer($0) }
        separators.forEach { root.addSublayer($0) }
        root.addSublayer(status)
    }

    /// Build every reusable band while idle. Showing or switching the picker only moves layers.
    func prepare(theme: ResolvedTheme) {
        style = theme.hud
        bottomInset = theme.picker.hudBottomInset
        HUD.stylePanel(root, style: style)
        HUD.configure(status, font: style.textFont, color: style.muted, scale: scale)
        prepared.removeAll()
        layoutContent = nil
        bands.forEach { $0.sublayers?.forEach { $0.removeFromSuperlayer() } }
        separators.forEach { $0.backgroundColor = style.panel.border.cgColor }
        for type in CaptureType.allCases {
            for picker in Picker.allCases {
                for accessibility in [false, true] {
                    for history in [false, true] {
                        for region in RegionState.allCases {
                            for countdown in [false, true] {
                                let content = Content(captureType: type, picker: picker, accessibilityAvailable: accessibility,
                                    historyAvailable: history, regionState: region, isCountingDown: countdown)
                                for band in bandContent(content) where !prepared.contains(where: { $0.content == band }) {
                                    var items: [(key: HUDKey?, layer: CALayer)] = []
                                    if !band.name.isEmpty {
                                        items.append((nil, HUD.makeName(band.name,
                                            rowHeight: HUD.textSize(band.name, font: style.nameFont).height, scale: scale, style: style)))
                                    }
                                    for (index, key) in band.keys.enumerated() {
                                        let displayed = key.action == "Copy" ? HUDKey("↵", action: "Copy to clipboard") : key
                                        let entry = HUD.makeEntry(displayed, scale: scale, style: style)
                                        if band.active != nil && index < 4 { HUD.pad(entry, style: style) }
                                        if band.active == index {
                                            HUD.highlight(entry, color: theme.editor.active, text: theme.editor.activeText, style: style)
                                        }
                                        items.append((key, entry.layer))
                                    }
                                    prepared.append(PreparedBand(content: band, items: items))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bandContent(_ content: Content) -> [Band] {
        [Band(name: content.captureName, keys: content.navigation),
         Band(keys: (content.typeSwitch.map { [$0] } ?? []) + content.actions,
              actionsStart: content.typeSwitch == nil ? 0 : 1)]
    }

    func show(_ content: Content, status message: String, size: CGSize, visible: Bool) {
        root.isHidden = !visible
        guard visible else { return }
        let contents = bandContent(content)
        var naturalWidth: CGFloat = 0
        for content in contents {
            guard let cached = prepared.first(where: { $0.content == content }) else { continue }
            let itemWidth = cached.items.reduce(CGFloat.zero) { $0 + $1.layer.frame.width }
            let gaps = CGFloat(max(0, cached.items.count - 1)) * style.entryGap
            let separation: CGFloat = content.actionsStart == nil ? 0 : 32
            naturalWidth = max(naturalWidth, itemWidth + gaps + separation)
        }
        let allTopItems = prepared.first(where: { $0.content == contents[0] })?.items.map(\.layer) ?? []
        let topPrefixCount = contents[0].name.isEmpty ? 0 : 1
        let topItems = Array(allTopItems.dropFirst(topPrefixCount))
        let bottomItems = prepared.first(where: { $0.content == contents[1] })?.items.map(\.layer) ?? []
        let prefixCount = contents[1].actionsStart ?? 0
        let actionItems = Array(bottomItems.dropFirst(prefixCount))
        var sizingContent = content
        sizingContent.captureType = .screenshot
        let columnCount = max(topItems.count, max(actionItems.count, sizingContent.actions.count))
        // Cancel stays in the last column when Video has no Edit action.
        let actionColumns = actionItems.indices.map { index in
            index == actionItems.count - 1 ? columnCount - 1 : index
        }
        var columnWidths = Array(repeating: CGFloat.zero, count: columnCount)
        for (index, item) in topItems.enumerated() { columnWidths[index] = item.frame.width }
        for (index, item) in actionItems.enumerated() {
            let column = actionColumns[index]
            columnWidths[column] = max(columnWidths[column], item.frame.width)
        }
        let bottomPrefixWidth = bottomItems.prefix(prefixCount).reduce(CGFloat.zero) { $0 + $1.frame.width } +
            CGFloat(max(0, prefixCount - 1)) * style.entryGap
        var prefixWidth = max(bottomPrefixWidth, allTopItems.first.map { topPrefixCount == 0 ? 0 : $0.frame.width } ?? 0)
        // Reserve the same columns for both capture types, including Screenshot's
        // Copy/Edit actions and Video's longer switch label.
        for type in CaptureType.allCases {
            var variant = content
            variant.captureType = type
            let variantBands = bandContent(variant)
            let top = prepared.first(where: { $0.content == variantBands[0] })?.items ?? []
            let bottom = prepared.first(where: { $0.content == variantBands[1] })?.items ?? []
            let prefix = variantBands[1].actionsStart ?? 0
            let prefixItemsWidth = bottom.prefix(prefix).reduce(CGFloat.zero) { $0 + $1.layer.frame.width }
            prefixWidth = max(prefixWidth, prefixItemsWidth + CGFloat(max(0, prefix - 1)) * style.entryGap)
            prefixWidth = max(prefixWidth, top.first?.layer.frame.width ?? 0)
            let actions = Array(bottom.dropFirst(prefix))
            for (index, item) in actions.enumerated() {
                let column = index == actions.count - 1 ? columnCount - 1 : index
                if columnWidths.indices.contains(column) {
                    columnWidths[column] = max(columnWidths[column], item.layer.frame.width)
                }
            }
            for band in [top, bottom] {
                let itemsWidth = band.reduce(CGFloat.zero) { $0 + $1.layer.frame.width }
                naturalWidth = max(naturalWidth, itemsWidth + CGFloat(max(0, band.count - 1)) * style.entryGap + 32)
            }
        }
        let columnStart = prefixWidth + 32
        var columnX: [CGFloat] = []
        var columnEnd = columnStart
        for width in columnWidths {
            columnX.append(columnEnd)
            columnEnd += width + style.entryGap
        }
        let alignedWidth = columnEnd - (columnCount == 0 ? 0 : style.entryGap)
        if !topItems.isEmpty { naturalWidth = max(naturalWidth, alignedWidth) }
        let width = max(1, min(naturalWidth, size.width - 2 * bottomInset - 2 * style.padding.width))
        let usesColumns = !topItems.isEmpty && alignedWidth <= width
        if layoutContent != content || layoutWidth != width {
            visibleItems.removeAll(keepingCapacity: true)
            var y = style.padding.height
            // Actions remain at the bottom, capture type at the top. Status grows above all three.
            for index in (0..<bands.count).reversed() {
                let band = bands[index]
                band.sublayers?.forEach { $0.removeFromSuperlayer() }
                guard let cached = prepared.first(where: { $0.content == contents[index] }), !cached.items.isEmpty else {
                    band.isHidden = true
                    if index > 0 { separators[index - 1].isHidden = true }
                    continue
                }
                band.isHidden = false
                let height = flow(cached.items.map(\.layer), width: width, in: band, actionsStart: contents[index].actionsStart,
                                  hasHeading: !contents[index].name.isEmpty)
                if usesColumns {
                    if index == 0 {
                        for (column, item) in cached.items.dropFirst(topPrefixCount).enumerated() {
                            item.layer.frame.origin.x = (columnX[column] * scale).rounded() / scale
                        }
                    } else {
                        for (action, item) in cached.items.dropFirst(prefixCount).enumerated() {
                            item.layer.frame.origin.x = (columnX[actionColumns[action]] * scale).rounded() / scale
                        }
                    }
                }
                band.frame = CGRect(x: style.padding.width, y: y, width: width, height: height)
                visibleItems.append(contentsOf: cached.items)
                y += height
                if index > 0 {
                    let separator = separators[index - 1]
                    separator.isHidden = content.isCountingDown
                    if !separator.isHidden {
                        y += style.lineGap
                        separator.frame = CGRect(x: style.padding.width, y: y, width: width, height: style.panel.borderWidth)
                        y += style.panel.borderWidth + style.lineGap
                    } else { y += style.lineGap }
                }
            }
            contentHeight = y
            layoutContent = content
            layoutWidth = width
        }
        let y = contentHeight
        let textHeight = message.isEmpty ? 0 : ceil((message as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: style.textFont]).height)
        status.isHidden = message.isEmpty
        status.isWrapped = true
        status.frame = CGRect(x: style.padding.width, y: y + style.lineGap, width: width, height: textHeight)
        status.string = message
        let height = y + style.padding.height + (message.isEmpty ? 0 : textHeight + style.lineGap)
        root.frame = CGRect(x: ((size.width - width) / 2 - style.padding.width).rounded(), y: bottomInset,
            width: width + 2 * style.padding.width, height: height)
        root.shadowPath = style.panel.path(in: root.bounds)
    }

    func unavailableReason(at point: CGPoint) -> String? {
        guard !root.isHidden, root.frame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - root.frame.minX, y: point.y - root.frame.minY)
        return visibleItems.first { !$0.layer.isHidden && $0.layer.bounds.contains($0.layer.convert(local, from: root)) }?.key?.unavailableReason
    }

    func contains(_ point: CGPoint) -> Bool {
        !root.isHidden && root.frame.contains(point)
    }

    /// Keep output actions on the right, wrapping whole entries on compact displays.
    private func flow(_ items: [CALayer], width: CGFloat, in band: CALayer, actionsStart: Int?, hasHeading: Bool) -> CGFloat {
        let total = items.reduce(CGFloat.zero) { $0 + $1.frame.width } + CGFloat(max(0, items.count - 1)) * style.entryGap
        if let actionsStart, total + 32 <= width {
            let height = items.map(\.frame.height).max() ?? 0
            let right = items.dropFirst(actionsStart)
            let rightWidth = right.reduce(CGFloat.zero) { $0 + $1.frame.width } + CGFloat(max(0, right.count - 1)) * style.entryGap
            var x: CGFloat = 0
            for (index, item) in items.enumerated() {
                if index == actionsStart { x = width - rightWidth }
                let y = index == 0 && hasHeading
                    ? HUD.textY(style.nameFont, lineHeight: item.frame.height, in: height, scale: scale)
                    : ((height - item.frame.height) / 2 * scale).rounded() / scale
                item.frame.origin = CGPoint(x: (x * scale).rounded() / scale, y: y)
                band.addSublayer(item)
                x += item.frame.width + style.entryGap
            }
            return height
        }
        var rows: [[CALayer]] = [[]]
        var x: CGFloat = 0
        for item in items {
            if x > 0 && x + item.frame.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(item)
            x += item.frame.width + style.entryGap
        }
        var y: CGFloat = 0
        for row in rows.reversed() {
            let height = row.map(\.frame.height).max() ?? 0
            let rowWidth = row.reduce(CGFloat.zero) { $0 + $1.frame.width }
            let gap = actionsStart == nil && rows.count == 1 && row.count > 1
                ? (width - rowWidth) / CGFloat(row.count - 1) : style.entryGap
            x = 0
            for item in row {
                let itemY = hasHeading && item === items.first
                    ? HUD.textY(style.nameFont, lineHeight: item.frame.height, in: height, scale: scale)
                    : ((height - item.frame.height) / 2 * scale).rounded() / scale
                item.frame.origin = CGPoint(x: (x * scale).rounded() / scale, y: y + itemY)
                band.addSublayer(item)
                x += item.frame.width + gap
            }
            y += height + style.lineGap
        }
        return max(0, y - style.lineGap)
    }
}
