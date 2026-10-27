import AppKit
import ImageIO

enum HistoryRetention: Int, CaseIterable {
    case off = 0, oneDay = 1, threeDays = 3, sevenDays = 7, thirtyDays = 30
    var label: String { self == .off ? "Off" : "\(rawValue) \(rawValue == 1 ? "day" : "days")" }
}

struct HistoryEntry: Codable, Equatable {
    var schema = 1
    let id: UUID
    var revision: UUID
    let createdAt: Date
    var modifiedAt: Date
    let scale: CGFloat
    let label: String
    let windowTitle: String
    var snapshot: EditSnapshot
    var undo: [EditSnapshot]
    var recognizedText: String?
    /// Optional for schema-1 compatibility. Unknown present values are rejected by the store.
    var annotationStyle: ThemeID?

    var annotationStyleID: ThemeID { annotationStyle ?? .pixel }

    var searchFields: [String] {
        // Fully visible annotation strings are exact searchable data even before OCR completes.
        // Partially clipped strings rely on rendered OCR so hidden characters never leak.
        let style = ThemeCatalog.annotation(annotationStyleID)
        let text = snapshot.annotations.compactMap { annotation -> String? in
            guard case let .text(text, at, _) = annotation else { return nil }
            if let crop = snapshot.crop, !crop.contains(AnnotationRenderer.textBounds(text, at: at, style: style)) { return nil }
            return text
        }.joined(separator: "\n")
        return [label, windowTitle, recognizedText ?? "", text]
    }
}

extension HistoryEntry {
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schema = try fields.decode(Int.self, forKey: .schema)
        id = try fields.decode(UUID.self, forKey: .id)
        revision = try fields.decode(UUID.self, forKey: .revision)
        createdAt = try fields.decode(Date.self, forKey: .createdAt)
        modifiedAt = try fields.decode(Date.self, forKey: .modifiedAt)
        scale = try fields.decode(CGFloat.self, forKey: .scale)
        label = try fields.decode(String.self, forKey: .label)
        windowTitle = try fields.decode(String.self, forKey: .windowTitle)
        snapshot = try fields.decode(EditSnapshot.self, forKey: .snapshot)
        undo = try fields.decode([EditSnapshot].self, forKey: .undo)
        recognizedText = try fields.decodeIfPresent(String.self, forKey: .recognizedText)
        if fields.contains(.annotationStyle) {
            guard let value = try? fields.decode(ThemeID.self, forKey: .annotationStyle) else {
                throw SettingsError(message: "Unsupported History entry \(id).")
            }
            annotationStyle = value
        } else {
            annotationStyle = nil
        }
    }
}

struct HistoryDocument {
    let entry: HistoryEntry
    var document: EditDocument
    var undo: [EditSnapshot] { entry.undo }
}

/// Synchronous disk boundary. Production calls are serialized on HistoryLibrary's worker queue.
/// The atomic entry.json switch publishes immutable revision assets only after all writes succeed.
final class HistoryStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vishot/History", isDirectory: true)
    let url: URL
    private let files = FileManager.default
    private(set) var warnings: [String] = []
    private var deleted: [UUID] = []

    init(url: URL = defaultURL) { self.url = url }

    private func folder(_ id: UUID) -> URL { url.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func metadata(_ id: UUID) -> URL { folder(id).appendingPathComponent("entry.json") }
    private func read(_ id: UUID) throws -> HistoryEntry {
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: metadata(id)))
        guard entry.schema == 1, entry.id == id else {
            throw SettingsError(message: "Unsupported History entry \(id).")
        }
        guard entry.scale.isFinite, entry.scale > 0 else { throw SettingsError(message: "Invalid History scale.") }
        for snapshot in [entry.snapshot] + entry.undo {
            func valid(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000 }
            func validRect(_ rect: CGRect) -> Bool { valid(rect.origin) && valid(CGPoint(x: rect.maxX, y: rect.maxY)) && rect.width >= 0 && rect.height >= 0 }
            if let crop = snapshot.crop, !validRect(crop) { throw SettingsError(message: "Invalid History crop.") }
            for annotation in snapshot.annotations {
                let isValid: Bool
                switch annotation {
                case let .arrow(from, to, _): isValid = valid(from) && valid(to)
                case let .rect(rect, _): isValid = validRect(rect)
                case let .text(text, at, _): isValid = valid(at) && text.count <= 100_000
                }
                guard isValid else { throw SettingsError(message: "Invalid History annotation geometry.") }
            }
        }
        return entry
    }

    func entries() throws -> [HistoryEntry] {
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        warnings = []
        var entries: [HistoryEntry] = []
        for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            do {
                if files.fileExists(atPath: child.appendingPathComponent("deleted").path) { continue }
                let entry = try read(id)
                guard files.fileExists(atPath: child.appendingPathComponent("original.png").path),
                      files.fileExists(atPath: asset(entry, "preview").path),
                      files.fileExists(atPath: asset(entry, "thumbnail").path) else {
                    throw SettingsError(message: "Missing image data.")
                }
                entries.append(entry)
            } catch { warnings.append("History entry \(id): \(error.localizedDescription)") }
        }
        return entries.sorted { $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt }
    }

    private func asset(_ entry: HistoryEntry, _ name: String) -> URL {
        folder(entry.id).appendingPathComponent("\(entry.revision.uuidString)-\(name).png")
    }

    @discardableResult
    func commit(document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String = "",
                id: UUID? = nil, now: Date = Date()) throws -> HistoryEntry {
        let previous = try id.map(read)
        if let previous, previous.snapshot == document.snapshot,
           previous.annotationStyleID == document.annotationStyle { return previous }
        guard document.scale.isFinite, document.scale > 0,
              let preview = AnnotationRenderer.export(document),
              let previewData = ImageEncoding.data(preview, scale: document.scale, type: .png),
              let thumbnail = Self.thumbnail(preview),
              let thumbnailData = ImageEncoding.data(thumbnail, scale: 1, type: .png) else {
            throw SettingsError(message: "Could not prepare History image.")
        }
        let entry = HistoryEntry(id: previous?.id ?? UUID(), revision: UUID(), createdAt: previous?.createdAt ?? now,
            modifiedAt: now, scale: document.scale, label: previous?.label ?? label,
            windowTitle: previous?.windowTitle ?? windowTitle, snapshot: document.snapshot, undo: undo,
            annotationStyle: document.annotationStyle)
        let directory = folder(entry.id)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var published = false
        defer {
            if !published {
                try? files.removeItem(at: asset(entry, "preview"))
                try? files.removeItem(at: asset(entry, "thumbnail"))
                if previous == nil { try? files.removeItem(at: directory) }
            }
        }
        if previous == nil {
            guard let data = ImageEncoding.data(document.image, scale: document.scale, type: .png) else {
                throw SettingsError(message: "Could not encode History original.")
            }
            try data.write(to: directory.appendingPathComponent("original.png"), options: .atomic)
        }
        try previewData.write(to: asset(entry, "preview"), options: .atomic)
        try thumbnailData.write(to: asset(entry, "thumbnail"), options: .atomic)
        try JSONEncoder().encode(entry).write(to: metadata(entry.id), options: .atomic)
        published = true
        if let previous {
            try? files.removeItem(at: asset(previous, "preview"))
            try? files.removeItem(at: asset(previous, "thumbnail"))
        }
        return entry
    }

    func load(_ id: UUID) throws -> HistoryDocument {
        let entry = try read(id)
        let image = try Self.image(at: folder(id).appendingPathComponent("original.png"))
        guard entry.scale.isFinite, entry.scale > 0 else { throw SettingsError(message: "Invalid History image scale.") }
        var document = EditDocument(image: image, scale: entry.scale, annotationStyle: entry.annotationStyleID)
        document.snapshot = entry.snapshot
        let bounds = CGRect(origin: .zero, size: document.size)
        for snapshot in [entry.snapshot] + entry.undo {
            if let crop = snapshot.crop {
                guard !crop.isEmpty, !crop.isInfinite, bounds.contains(crop) else {
                    throw SettingsError(message: "Invalid History crop.")
                }
            }
            func contains(_ point: CGPoint) -> Bool {
                point.x >= 0 && point.y >= 0 && point.x <= bounds.maxX && point.y <= bounds.maxY
            }
            for annotation in snapshot.annotations {
                let valid: Bool
                switch annotation {
                case let .arrow(from, to, _): valid = contains(from) && contains(to)
                case let .rect(rect, _): valid = contains(rect.origin) && contains(CGPoint(x: rect.maxX, y: rect.maxY))
                case let .text(_, at, _): valid = contains(at)
                }
                guard valid else { throw SettingsError(message: "History annotation lies outside its source image.") }
            }
        }
        return HistoryDocument(entry: entry, document: document)
    }

    func preview(_ entry: HistoryEntry, thumbnail: Bool = false, maxPixelSize: Int? = nil) throws -> CGImage {
        let url = asset(entry, thumbnail ? "thumbnail" : "preview")
        if let maxPixelSize {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { throw SettingsError(message: "Could not read History preview.") }
            return image
        }
        return try Self.image(at: url)
    }

    /// Snapshot the bytes while publication/deletion is excluded by the library's worker.
    /// An old browser entry is obsolete, not evidence of damaged storage.
    func previewData(_ entry: HistoryEntry, thumbnail: Bool) throws -> Data? {
        let directory = folder(entry.id)
        guard files.fileExists(atPath: metadata(entry.id).path),
              !files.fileExists(atPath: directory.appendingPathComponent("deleted").path) else { return nil }
        guard try read(entry.id).revision == entry.revision else { return nil }
        return try Data(contentsOf: asset(entry, thumbnail ? "thumbnail" : "preview"))
    }

    static func previewImage(_ data: Data, maxPixelSize: Int?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw SettingsError(message: "Could not read History preview.")
        }
        let image: CGImage?
        if let maxPixelSize {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { throw SettingsError(message: "Could not read History preview.") }
        return image
    }

    @discardableResult
    func index(_ id: UUID, revision: UUID, text: String) throws -> Bool {
        guard !files.fileExists(atPath: folder(id).appendingPathComponent("deleted").path),
              let entry = try? read(id), entry.revision == revision else { return false }
        var indexed = entry
        indexed.recognizedText = text
        try JSONEncoder().encode(indexed).write(to: metadata(id), options: .atomic)
        return true
    }

    func delete(_ id: UUID) throws {
        _ = try read(id)
        guard !deleted.contains(id) else { return }
        try Data().write(to: folder(id).appendingPathComponent("deleted"), options: .atomic)
        deleted.append(id)
    }

    @discardableResult
    func undoDelete() throws -> UUID? {
        guard let id = deleted.last else { return nil }
        try files.removeItem(at: folder(id).appendingPathComponent("deleted"))
        deleted.removeLast()
        return id
    }

    func finishDeletions() throws {
        for id in deleted { if files.fileExists(atPath: folder(id).path) { try files.removeItem(at: folder(id)) } }
        deleted = []
    }

    /// Called on startup only: interrupted deletions and orphan revision files are not recoverable.
    func recover() throws {
        _ = try entries()
        for directory in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            if files.fileExists(atPath: directory.appendingPathComponent("deleted").path) {
                try files.removeItem(at: directory)
            } else if !files.fileExists(atPath: metadata(id).path) {
                try files.removeItem(at: directory)
            } else if let entry = try? read(id) {
                let keep: Set<String> = ["entry.json", "original.png", asset(entry, "preview").lastPathComponent, asset(entry, "thumbnail").lastPathComponent]
                for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where !keep.contains(file.lastPathComponent) { try files.removeItem(at: file) }
            }
        }
    }

    func cleanup(retention: HistoryRetention, holding: Set<UUID> = [], now: Date = Date()) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        let policyURL = url.appendingPathComponent("retention.json")
        let stored = (try? JSONDecoder().decode(Int.self, from: Data(contentsOf: policyURL))) ?? 7
        let days = retention == .off ? (HistoryRetention(rawValue: stored).flatMap { $0 == .off ? nil : $0 }?.rawValue ?? 7) : retention.rawValue
        if retention != .off { try JSONEncoder().encode(days).write(to: policyURL, options: .atomic) }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        for entry in try entries() where entry.modifiedAt <= cutoff && !holding.contains(entry.id) {
            try files.removeItem(at: folder(entry.id))
        }
    }

    func clear() throws {
        // Leave unsupported/malformed entries untouched during ordinary cleanup, but explicit Clear
        // removes all private history data, including those entries.
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        deleted = []
    }

    func diskUsage() throws -> Int64 {
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SettingsError(message: "Could not read History image \(url.lastPathComponent).")
        }
        return image
    }

    private static func thumbnail(_ image: CGImage) -> CGImage? {
        let ratio = min(1, 320 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * ratio)), height = max(1, Int(CGFloat(image.height) * ratio))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
