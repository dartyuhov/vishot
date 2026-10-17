import AppKit
import Carbon.HIToolbox

/// The browser owns input/selection; OverlayController owns its session and editor transitions.
final class HistoryBrowser: NSObject, NSWindowDelegate {
    private let library: HistoryLibrary
    private var panel: HistoryPanel?
    private var view: HistoryView?
    private var selectedID: UUID?
    private var query = ""
    private var searching = false
    private var generation = 0
    private var thumbnailCache: [UUID: (UUID, CGImage)] = [:]
    private var pendingThumbnails: Set<UUID> = []
    private var previewRevision: UUID?
    private var preview: CGImage?
    private var previewRequest: HistoryImageRequest?
    private var yankRequest: HistoryImageRequest?
    private var thumbnailRequests: [UUID: HistoryImageRequest] = [:]
    private var hiddenIDs: Set<UUID> = []
    private var busy = false
    private var cachedResults: [HistoryEntry] = []
    private var cachedQuery: String?
    var onClose: (() -> Void)?
    var onEdit: ((UUID, NSScreen) -> Void)?
    var onYank: ((HistoryEntry) -> Void)?
    private(set) var screen: NSScreen?
    private var results: [HistoryEntry] {
        if cachedQuery != query {
            cachedResults = HistorySearch.matches(query, in: library.entries.filter { !hiddenIDs.contains($0.id) })
            cachedQuery = query
        }
        return cachedResults
    }
    private var selected: HistoryEntry? { results.first { $0.id == selectedID } }

    init(library: HistoryLibrary) {
        self.library = library
        super.init()
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = HistoryPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onKey = { [weak self] in self?.handle($0) }
        let view = HistoryView(frame: CGRect(origin: .zero, size: frame.size))
        view.onSelect = { [weak self] id in self?.selectedID = id; self?.refresh() }
        view.onScroll = { [weak self] in self?.move($0) }
        panel.contentView = view
        self.panel = panel
        self.view = view
    }

    func setBusy(_ busy: Bool) { self.busy = busy }

    func yank(_ entry: HistoryEntry, completion: @escaping (CGImage?) -> Void) {
        guard !busy else { return }
        busy = true
        let generation = generation
        yankRequest = library.image(entry, thumbnail: false) { [weak self] image in
            guard let self, self.generation == generation else { return }
            self.yankRequest = nil
            self.busy = false
            completion(image)
        }
    }

    func show(on screen: NSScreen) {
        self.screen = screen
        panel?.setFrame(screen.frame, display: false)
        view?.frame = CGRect(origin: .zero, size: screen.frame.size)
        panel?.delegate = self
        hiddenIDs = []
        cachedQuery = nil
        query = ""
        searching = false
        busy = false
        selectedID = library.entries.first?.id
        view?.showLoading()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        panel?.displayIfNeeded()
        // Present feedback before metadata/layout or image requests begin.
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, self.panel?.isVisible == true else { return }
            self.refresh()
        }
    }

    func suspend() { panel?.orderOut(nil) }
    func resume(select id: UUID) {
        searching = false
        query = ""
        selectedID = id
        previewRevision = nil
        refresh()
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func close() {
        generation += 1
        yankRequest?.cancel()
        yankRequest = nil
        busy = false
        cachedQuery = nil
        cachedResults = []
        panel?.delegate = nil
        panel?.orderOut(nil)
        thumbnailCache = [:]
        pendingThumbnails = []
        preview = nil
        previewRequest?.cancel()
        thumbnailRequests.values.forEach { $0.cancel() }
        thumbnailRequests = [:]
        previewRevision = nil
        view?.preview = nil
        view?.thumbnails = [:]
        view?.items = []
        view?.hideLoading()
    }

    func refresh() {
        guard panel?.delegate != nil, let view else { return }
        let matches = results
        if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
        let index = matches.firstIndex { $0.id == selectedID } ?? 0
        let capacity = max(1, Int((view.bounds.width - 64) / 180))
        let start = min(max(0, index - capacity / 2), max(0, matches.count - capacity))
        let visible = Array(matches.dropFirst(start).prefix(capacity))
        // Keep only the visible strip in memory.
        let visibleIDs = Set(visible.map(\.id))
        let revisions = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.revision) })
        let previousRevisions = Dictionary(uniqueKeysWithValues: view.items.map { ($0.id, $0.revision) })
        thumbnailCache = thumbnailCache.filter { revisions[$0.key] == $0.value.0 }
        for id in Array(thumbnailRequests.keys) where !visibleIDs.contains(id) || previousRevisions[id] != revisions[id] {
            thumbnailRequests.removeValue(forKey: id)?.cancel()
            pendingThumbnails.remove(id)
        }
        view.items = visible
        view.thumbnails = thumbnailCache.mapValues(\.1)
        view.selectedID = selectedID
        view.title = "HISTORY"
        view.query = searching ? "/" + query + "▏" : ""
        view.keys = searching ? [HUDKey("←", "→", action: "select"), HUDKey("↵", action: "accept"), HUDKey("esc", action: "back")]
            : [HUDKey("h/l", action: "move"), HUDKey("y", action: "yank"), HUDKey("e", action: "edit"),
               HUDKey("/", action: "search"), HUDKey("d", action: "delete"), HUDKey("u", action: "restore"), HUDKey("esc", action: "close")]
        if let entry = selected {
            let date = DateFormatter.localizedString(from: entry.createdAt, dateStyle: .medium, timeStyle: .short)
            view.status = "\(index + 1)/\(matches.count) · \(entry.label) · \(date)" + (entry.recognizedText == nil ? " · indexing…" : "")
            if previewRevision != entry.revision {
                previewRequest?.cancel()
                previewRevision = entry.revision
                preview = nil
                previewRequest = nil
            }
            view.empty = "Loading preview…"
        } else {
            view.hideLoading()
            previewRequest?.cancel()
            preview = nil
            previewRevision = nil
            view.status = library.error ?? ""
            view.empty = searching && !query.isEmpty ? "No matches" : "No captures yet. Copy or save a screenshot to keep it here."
        }
        view.preview = preview ?? selected.flatMap { entry in
            thumbnailCache[entry.id].flatMap { $0.0 == entry.revision ? $0.1 : nil }
        }
        view.updateHUD()
        view.needsDisplay = true
        for entry in visible where thumbnailCache[entry.id]?.0 != entry.revision && !pendingThumbnails.contains(entry.id) {
            pendingThumbnails.insert(entry.id)
            let generation = generation
            thumbnailRequests[entry.id] = library.image(entry, thumbnail: true) { [weak self] image in
                guard let self, self.generation == generation else { return }
                self.pendingThumbnails.remove(entry.id)
                self.thumbnailRequests.removeValue(forKey: entry.id)
                if let image, self.view?.items.contains(where: { $0.id == entry.id && $0.revision == entry.revision }) == true {
                    self.thumbnailCache[entry.id] = (entry.revision, image)
                    if self.selected?.revision == entry.revision, self.preview == nil {
                        self.view?.preview = image
                        self.loadSelectedPreview()
                    }
                }
                self.view?.thumbnails = self.thumbnailCache.mapValues(\.1)
                self.view?.needsDisplay = true
            }
        }
        // Enqueue every visible thumbnail before any full-size read. Only the current
        // selection gets a full image, and obsolete queued requests are cancelled.
        if let entry = selected, thumbnailCache[entry.id]?.0 == entry.revision {
            loadSelectedPreview()
        }
    }

    private func loadSelectedPreview() {
        guard previewRequest == nil, let entry = selected, previewRevision == entry.revision else { return }
        let revision = entry.revision, generation = generation
        let pixelSize = Int(max(screen?.frame.width ?? 1200, screen?.frame.height ?? 800)
            * (screen?.backingScaleFactor ?? 2))
        previewRequest = library.image(entry, thumbnail: false, maxPixelSize: pixelSize) { [weak self] image in
            guard let self, self.generation == generation, self.previewRevision == revision else { return }
            self.preview = image
            if let image { self.view?.preview = image }
            self.view?.needsDisplay = true
        }
    }

    func libraryChanged() { cachedQuery = nil; refresh() }

    private func move(_ step: Int) {
        let matches = results
        guard !matches.isEmpty else { return }
        let index = matches.firstIndex { $0.id == selectedID } ?? 0
        selectedID = matches[min(max(0, index + step), matches.count - 1)].id
        refresh()
    }

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        guard !busy else { return }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return }
        if searching {
            switch code {
            case kVK_LeftArrow: move(-1)
            case kVK_RightArrow: move(1)
            case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape: searching = false; query = ""
            case kVK_Delete: query = String(query.dropLast())
            default:
                query += (event.characters ?? "").filter { character in
                    character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }
                }
            }
        } else {
            switch code {
            case kVK_ANSI_H, kVK_LeftArrow: move(-1)
            case kVK_ANSI_L, kVK_RightArrow: move(1)
            case kVK_ANSI_Y:
                if !event.isARepeat, let entry = selected { onYank?(entry) }
            case kVK_ANSI_E:
                if !event.isARepeat, let id = selectedID, let screen { onEdit?(id, screen) }
            case kVK_ANSI_Slash: searching = true
            case kVK_ANSI_D:
                guard !event.isARepeat else { return }
                if let id = selectedID {
                    hiddenIDs.insert(id)
                    cachedQuery = nil
                    library.delete(id) { [weak self] success in
                        if !success { self?.hiddenIDs.remove(id); self?.libraryChanged() }
                    }
                }
            case kVK_ANSI_U:
                guard !event.isARepeat else { return }
                library.undoDelete { [weak self] id in
                    if let id { self?.hiddenIDs.remove(id); self?.selectedID = id; self?.libraryChanged() }
                }
            case kVK_Escape: onClose?()
            default: break
            }
        }
        refresh()
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel?.isVisible == true, self.panel?.isKeyWindow == false else { return }
            self.onClose?()
        }
    }
}

private final class HistoryPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

private final class HistoryView: NSView {
    var items: [HistoryEntry] = []
    var thumbnails: [UUID: CGImage] = [:]
    var selectedID: UUID?
    var preview: CGImage? {
        didSet {
            if preview != nil { hideLoading() }
            else if !items.isEmpty { showLoading() }
        }
    }
    var title = "", status = "", query = "", empty = ""
    var keys: [HUDKey] = []
    var onSelect: ((UUID) -> Void)?
    var onScroll: ((Int) -> Void)?
    private var hits: [(UUID, CGRect)] = []
    private var scrollRemainder: CGFloat = 0
    private let hud = CALayer()
    private var hudHeight: CGFloat = 100
    private let spinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading captures…")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        HUD.stylePanel(hud)
        layer?.addSublayer(hud)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        loadingLabel.font = Fonts.mono(14)
        loadingLabel.textColor = Palette.text
        loadingLabel.alignment = .center
        addSubview(spinner)
        addSubview(loadingLabel)
        hideLoading()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture History")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLoading() {
        spinner.frame = CGRect(x: bounds.midX - 16, y: bounds.midY + 24, width: 32, height: 32)
        loadingLabel.frame = CGRect(x: max(0, bounds.midX - 180), y: bounds.midY - 12, width: min(360, bounds.width), height: 24)
        loadingLabel.isHidden = false
        spinner.startAnimation(nil)
    }

    func hideLoading() {
        spinner.stopAnimation(nil)
        loadingLabel.isHidden = true
    }

    func updateHUD() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hud.sublayers?.forEach { $0.removeFromSuperlayer() }
        let width = min(bounds.width - 64, 1200), scale = window?.backingScaleFactor ?? 2
        var x: CGFloat = 16, y: CGFloat = 12
        // Wrap entries as complete units; no help key gets clipped on a small display.
        for key in keys {
            let entry = HUD.makeEntry(key, scale: scale).layer
            if x + entry.frame.width > width - 16, x > 16 { x = 16; y += 34 }
            entry.frame.origin = CGPoint(x: x, y: y)
            hud.addSublayer(entry)
            x += entry.frame.width + HUD.entryGap
        }
        y += 38
        let status = HUD.makeText(query.isEmpty ? status : query, font: Fonts.mono(13), color: Palette.text, scale: scale)
        status.frame = CGRect(x: 16, y: y, width: width - 32, height: 22)
        hud.addSublayer(status)
        let name = HUD.makeName(title, rowHeight: 24, scale: scale)
        name.frame.origin = CGPoint(x: 16, y: y + 28)
        hud.addSublayer(name)
        hudHeight = y + 62
        hud.frame = CGRect(x: (bounds.width - width) / 2, y: 24, width: width, height: hudHeight)
        hud.shadowPath = CGPath(rect: hud.bounds, transform: nil)
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.78).setFill()
        bounds.fill()
        let width = min(bounds.width - 64, 1200)
        let x = (bounds.width - width) / 2
        let stripY: CGFloat = 24 + hudHeight + 20, tileWidth: CGFloat = 164, tileHeight: CGFloat = 112
        let total = CGFloat(items.count) * 180 - 16
        let left = (bounds.width - max(0, total)) / 2
        hits = []
        for (index, entry) in items.enumerated() {
            let tile = CGRect(x: left + CGFloat(index) * 180, y: stripY, width: tileWidth, height: tileHeight)
            Palette.surface.setFill()
            tile.fill()
            if let image = thumbnails[entry.id] { draw(image, in: tile.insetBy(dx: 6, dy: 6)) }
            if entry.id == selectedID {
                // Match the picker's 4 pt purple pixel ring, including its cut-out corners.
                let ring = CGMutablePath()
                ring.addPixelRoundedRect(tile, pixel: 4)
                ring.addPixelRoundedRect(tile.insetBy(dx: 4, dy: 4), pixel: 4)
                if let context = NSGraphicsContext.current?.cgContext {
                    context.saveGState()
                    context.setFillColor(Palette.accent.cgColor)
                    context.addPath(ring)
                    context.drawPath(using: .eoFill)
                    context.restoreGState()
                }
            } else {
                Palette.line.setFill()
                tile.insetBy(dx: 1, dy: 1).frame(withWidth: 2)
            }
            hits.append((entry.id, tile))
        }
        let area = CGRect(x: x, y: stripY + 136, width: width, height: max(1, bounds.height - stripY - 168))
        if let preview { draw(preview, in: area) }
        else if loadingLabel.isHidden {
            text(empty, at: CGPoint(x: x, y: area.midY), font: Fonts.mono(14), color: .white, width: width)
        }
        setAccessibilityValue([status, query, keys.map { $0.keys.joined(separator: "/") + " " + $0.action }.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    private func text(_ value: String, at point: CGPoint, font: NSFont, color: NSColor, width: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: CGRect(x: point.x, y: point.y, width: width, height: 22),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func draw(_ image: CGImage, in area: CGRect) {
        let ratio = min(area.width / CGFloat(image.width), area.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        NSImage(cgImage: image, size: size).draw(in: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hits.first(where: { $0.1.contains(point) }) { onSelect?(hit.0) }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollRemainder += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        if abs(scrollRemainder) >= threshold {
            onScroll?(scrollRemainder > 0 ? -1 : 1)
            scrollRemainder = 0
        }
    }
}
