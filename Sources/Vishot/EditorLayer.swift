import AppKit

private enum Style {
    static let outsideDim = NSColor(white: 0, alpha: 0.45)
    static let cropDim = NSColor(white: 0, alpha: 0.7)
    static let cropOutline = NSColor(white: 1, alpha: 0.6)
    static let accent = NSColor.controlAccentColor
    static let crosshairArm: CGFloat = 12
    static let crosshairGap: CGFloat = 3

    static let background = NSColor(white: 0.1, alpha: 0.85)
    static let padding: CGFloat = 8
    /// Between the image and the toolbar, and between the toolbar and the screen edge.
    static let margin: CGFloat = 12
    static let floatingInset: CGFloat = 24
    static let buttonHeight: CGFloat = 24
    static let buttonPadding: CGFloat = 8
    static let buttonGap: CGFloat = 2
    static let groupGap: CGFloat = 12
    static let swatchSize: CGFloat = 16
    static let lineGap: CGFloat = 6
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let keyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let statusFont = NSFont.systemFont(ofSize: 12)
}

/// The editor on one panel: the frozen image, its annotations, the dimming around it, the cursor and,
/// on one screen, the toolbar. Built with the panel and hidden until editing.
final class EditorLayer: NSObject, CALayerDelegate {
    let root = CALayer()
    private let image = CALayer()
    private let annotations = CALayer()
    private let cropDim = CAShapeLayer()
    private let cropOutline = CALayer()
    private let outsideDim = CAShapeLayer()
    private let crosshair = CALayer()
    private let caret = CALayer()
    private let toolbar: EditorToolbar

    /// What the annotations layer draws, and where the image's top-left is in it (y up).
    private var drawn: [Annotation] = []
    private var drawnOffset = CGPoint.zero

    init(size: CGSize, scale: CGFloat) {
        toolbar = EditorToolbar(scale: scale)
        super.init()
        root.frame = CGRect(origin: .zero, size: size)
        root.isHidden = true

        image.contentsGravity = .resize
        annotations.delegate = self
        annotations.contentsScale = scale
        annotations.needsDisplayOnBoundsChange = true

        for (dim, color) in [(cropDim, Style.cropDim), (outsideDim, Style.outsideDim)] {
            dim.frame = root.bounds
            dim.fillRule = .evenOdd
            dim.fillColor = color.cgColor
        }
        cropOutline.borderWidth = 1

        // White on a darker outline, so it shows on any content.
        for (color, width) in [(NSColor(white: 0, alpha: 0.75), CGFloat(4)), (.white, 2)] {
            let arms = CAShapeLayer()
            arms.path = Self.crosshairPath()
            arms.strokeColor = color.cgColor
            arms.lineWidth = width
            arms.lineCap = .round
            crosshair.addSublayer(arms)
        }
        caret.cornerRadius = 1
        caret.borderColor = NSColor(white: 1, alpha: 0.8).cgColor
        caret.borderWidth = 0.5

        for layer in [image, annotations, cropDim, cropOutline, outsideDim, crosshair, caret, toolbar.root] {
            root.addSublayer(layer)
        }
    }

    private static func crosshairPath() -> CGPath {
        let path = CGMutablePath()
        let (gap, end) = (Style.crosshairGap, Style.crosshairGap + Style.crosshairArm)
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
            path.move(to: CGPoint(x: dx * gap, y: dy * gap))
            path.addLine(to: CGPoint(x: dx * end, y: dy * end))
        }
        return path
    }

    /// `panelFrame` is the panel's frame in Cocoa global space.
    func show(_ scene: EditorScene, panelFrame: CGRect, showsToolbar: Bool) {
        root.isHidden = false
        let bounds = root.bounds
        let imageRect = scene.frame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: imageRect.minX + point.x, y: imageRect.maxY - point.y)
        }
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: imageRect.minX + rect.minX, y: imageRect.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        if (image.contents as AnyObject?) !== scene.image { image.contents = scene.image }
        image.frame = imageRect

        // Only the part on this screen, so a window spanning screens doesn't get a backing store per screen.
        let visible = imageRect.intersection(bounds)
        annotations.isHidden = visible.isEmpty
        if !visible.isEmpty {
            annotations.frame = visible
            let offset = CGPoint(x: imageRect.minX - visible.minX, y: imageRect.maxY - visible.minY)
            if scene.annotations != drawn || offset != drawnOffset {
                drawn = scene.annotations
                drawnOffset = offset
                annotations.setNeedsDisplay()
            }
        }

        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addRect(imageRect)
        outsideDim.path = outside

        cropDim.isHidden = scene.crop == nil
        cropOutline.isHidden = scene.crop == nil
        if let crop = scene.crop.map(local) {
            let path = CGMutablePath()
            path.addRect(imageRect)
            path.addRect(crop)
            cropDim.path = path
            cropOutline.frame = crop.insetBy(dx: -1, dy: -1)
            cropOutline.borderColor = (scene.isCropping ? Style.accent : Style.cropOutline).cgColor
        }

        crosshair.isHidden = scene.cursor == nil
        if let cursor = scene.cursor { crosshair.position = local(cursor) }
        caret.isHidden = scene.caret == nil
        if let rect = scene.caret {
            caret.frame = local(rect)
            caret.backgroundColor = scene.color.cgColor
        }

        toolbar.root.isHidden = !showsToolbar
        if showsToolbar {
            toolbar.update(scene)
            toolbar.root.frame.origin = toolbarOrigin(around: visible.isEmpty ? imageRect : visible)
        }
    }

    /// Below the image if there is room, otherwise above it, otherwise inside its bottom edge.
    private func toolbarOrigin(around image: CGRect) -> CGPoint {
        let bounds = root.bounds
        let size = toolbar.root.frame.size
        let x = min(max(image.midX - size.width / 2, Style.margin), bounds.width - size.width - Style.margin)
        let y: CGFloat
        if image.minY - Style.margin - size.height >= Style.margin {
            y = image.minY - Style.margin - size.height
        } else if image.maxY + Style.margin + size.height <= bounds.height - Style.margin {
            y = image.maxY + Style.margin
        } else {
            y = max(image.minY, 0) + Style.floatingInset
        }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    func hide() {
        root.isHidden = true
        // Lets the capture go.
        image.contents = nil
        annotations.contents = nil
        drawn = []
    }

    /// `point` is in the panel's coordinates.
    func toolbarContains(_ point: CGPoint) -> Bool {
        !root.isHidden && !toolbar.root.isHidden && toolbar.root.frame.contains(point)
    }

    func toolbarItem(at point: CGPoint) -> ToolbarItem? {
        guard toolbarContains(point) else { return nil }
        let origin = toolbar.root.frame.origin
        return toolbar.item(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
    }

    // MARK: - CALayerDelegate

    func draw(_ layer: CALayer, in context: CGContext) {
        // Into image space: origin at the image's top-left, y down.
        context.translateBy(x: drawnOffset.x, y: drawnOffset.y)
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(drawn, in: context)
    }

    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// Buttons for the tools, colors, undo and redo, and the finishing actions, each with its key, above
/// a status line. Laid out once; updates only change highlights and the status.
private final class EditorToolbar {
    let root = CALayer()
    private var buttons: [(item: ToolbarItem, layer: CALayer)] = []
    private let status = CATextLayer()

    private static let groups: [[(item: ToolbarItem, title: String, key: String)]] = [
        EditorController.Tool.allCases.map { (.tool($0), $0.name, $0.key) },
        AnnotationColor.allCases.map { (.color($0), "", "") },
        [(.undo, "undo", "u"), (.redo, "redo", "⌃r")],
        [
            (.finish(.copy), "copy", "y"),
            (.finish(.save), "save", "s"),
            (.finish(.saveAndCopy), "save+copy", "S"),
            (.finish(.saveAs), "save as", "⌘s"),
            (.finish(.discard), "discard", "esc"),
        ],
    ]

    init(scale: CGFloat) {
        root.backgroundColor = Style.background.cgColor
        root.cornerRadius = 10

        let statusHeight = ceil(("Hg" as NSString).size(withAttributes: [.font: Style.statusFont]).height)
        let buttonY = Style.padding + statusHeight + Style.lineGap
        var x = Style.padding
        for group in Self.groups {
            for (item, title, key) in group {
                let button: CALayer
                if case .color(let color) = item {
                    button = Self.makeSwatch(color)
                } else {
                    button = Self.makeButton(title: title, key: key, scale: scale)
                }
                button.frame.origin = CGPoint(x: x, y: buttonY)
                root.addSublayer(button)
                buttons.append((item, button))
                x += button.frame.width + Style.buttonGap
            }
            x += Style.groupGap - Style.buttonGap
        }
        let width = x - Style.groupGap + Style.padding
        root.frame.size = CGSize(width: width, height: buttonY + Style.buttonHeight + Style.padding)

        status.font = Style.statusFont
        status.fontSize = Style.statusFont.pointSize
        status.foregroundColor = NSColor(white: 1, alpha: 0.7).cgColor
        status.contentsScale = scale
        status.truncationMode = .end
        status.frame = CGRect(x: Style.padding + 4, y: Style.padding, width: width - 2 * Style.padding - 8, height: statusHeight)
        root.addSublayer(status)
    }

    private static func makeButton(title: String, key: String, scale: CGFloat) -> CALayer {
        let string = NSMutableAttributedString(string: title, attributes: [.font: Style.titleFont, .foregroundColor: NSColor.white])
        string.append(NSAttributedString(
            string: " " + key,
            attributes: [.font: Style.keyFont, .foregroundColor: NSColor(white: 1, alpha: 0.5)]
        ))
        let size = string.size()
        let text = CATextLayer()
        text.string = string
        text.contentsScale = scale
        text.frame = CGRect(
            x: Style.buttonPadding, y: ((Style.buttonHeight - ceil(size.height)) / 2).rounded(),
            width: ceil(size.width), height: ceil(size.height)
        )
        let button = CALayer()
        button.cornerRadius = 6
        button.frame.size = CGSize(width: ceil(size.width) + 2 * Style.buttonPadding, height: Style.buttonHeight)
        button.addSublayer(text)
        return button
    }

    private static func makeSwatch(_ color: AnnotationColor) -> CALayer {
        let dot = CALayer()
        dot.backgroundColor = color.cgColor
        dot.cornerRadius = Style.swatchSize / 2
        dot.borderColor = NSColor(white: 1, alpha: 0.4).cgColor
        dot.borderWidth = 1
        let inset = (Style.buttonHeight - Style.swatchSize) / 2
        dot.frame = CGRect(x: inset, y: inset, width: Style.swatchSize, height: Style.swatchSize)
        let button = CALayer()
        button.cornerRadius = Style.buttonHeight / 2
        button.borderColor = NSColor.white.cgColor
        button.frame.size = CGSize(width: Style.buttonHeight, height: Style.buttonHeight)
        button.addSublayer(dot)
        return button
    }

    func update(_ scene: EditorScene) {
        for (item, layer) in buttons {
            switch item {
            case .tool(let tool):
                layer.backgroundColor = tool == scene.tool ? Style.accent.cgColor : nil
            case .color(let color):
                layer.borderWidth = color == scene.color ? 2 : 0
            case .undo:
                layer.opacity = scene.canUndo ? 1 : 0.35
            case .redo:
                layer.opacity = scene.canRedo ? 1 : 0.35
            case .finish:
                break
            }
        }
        status.string = scene.status
    }

    /// `point` is in the toolbar's coordinates.
    func item(at point: CGPoint) -> ToolbarItem? {
        buttons.first { $0.layer.frame.contains(point) }?.item
    }
}
