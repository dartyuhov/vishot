import AppKit
import ImageIO
import AVFoundation
import Darwin

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
    var video: HistoryVideo? = nil
    /// Transient disk availability; never written into retained metadata.
    var unavailable = false
    var canUseVideo: Bool { video != nil && !unavailable }

    private enum Keys: String, CodingKey {
        case schema, id, revision, createdAt, modifiedAt, label, windowTitle, payload
        case scale, snapshot, undo, recognizedText
    }
    private struct Screenshot: Codable {
        let scale: CGFloat
        let snapshot: EditSnapshot
        let undo: [EditSnapshot]
        let recognizedText: String?
    }
    private enum Payload: Codable { case screenshot(Screenshot), video(HistoryVideo) }

    init(schema: Int = 1, id: UUID, revision: UUID, createdAt: Date, modifiedAt: Date, scale: CGFloat,
         label: String, windowTitle: String, snapshot: EditSnapshot, undo: [EditSnapshot], recognizedText: String? = nil,
         video: HistoryVideo? = nil) {
        self.schema = schema; self.id = id; self.revision = revision
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.scale = scale
        self.label = label; self.windowTitle = windowTitle; self.snapshot = snapshot; self.undo = undo
        self.recognizedText = recognizedText; self.video = video
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        schema = try values.decode(Int.self, forKey: .schema)
        guard schema == 1 || schema == 2 else { throw SettingsError(message: "Unsupported History schema \(schema).") }
        id = try values.decode(UUID.self, forKey: .id)
        revision = try values.decode(UUID.self, forKey: .revision)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        label = try values.decode(String.self, forKey: .label)
        windowTitle = try values.decode(String.self, forKey: .windowTitle)
        if schema == 1 {
            scale = try values.decode(CGFloat.self, forKey: .scale)
            snapshot = try values.decode(EditSnapshot.self, forKey: .snapshot)
            undo = try values.decode([EditSnapshot].self, forKey: .undo)
            recognizedText = try values.decodeIfPresent(String.self, forKey: .recognizedText)
        } else {
            switch try values.decode(Payload.self, forKey: .payload) {
            case .screenshot(let screenshot):
                scale = screenshot.scale; snapshot = screenshot.snapshot; undo = screenshot.undo
                recognizedText = screenshot.recognizedText
            case .video(let payload):
                video = payload; scale = payload.scale
                snapshot = EditSnapshot(annotations: [], crop: nil); undo = []; recognizedText = nil
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(id, forKey: .id); try values.encode(revision, forKey: .revision)
        try values.encode(createdAt, forKey: .createdAt); try values.encode(modifiedAt, forKey: .modifiedAt)
        try values.encode(label, forKey: .label); try values.encode(windowTitle, forKey: .windowTitle)
        if schema == 1 {
            try values.encode(scale, forKey: .scale); try values.encode(snapshot, forKey: .snapshot)
            try values.encode(undo, forKey: .undo); try values.encodeIfPresent(recognizedText, forKey: .recognizedText)
        } else {
            let payload = video.map(Payload.video) ?? .screenshot(Screenshot(scale: scale, snapshot: snapshot, undo: undo, recognizedText: recognizedText))
            try values.encode(payload, forKey: .payload)
        }
    }

    var searchFields: [String] {
        if let video { return [label, windowTitle, video.movie] }
        // Fully visible annotation strings are exact searchable data even before OCR completes.
        // Partially clipped strings rely on rendered OCR so hidden characters never leak.
        let text = snapshot.annotations.compactMap { annotation -> String? in
            guard case let .text(text, at, _) = annotation else { return nil }
            if let crop = snapshot.crop, !crop.contains(AnnotationRenderer.textBounds(text, at: at)) { return nil }
            return text
        }.joined(separator: "\n")
        return [label, windowTitle, recognizedText ?? "", text]
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
        guard try folder(id).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw SettingsError(message: "History entry directory must be private storage.")
        }
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: metadata(id)))
        guard (entry.schema == 1 || entry.schema == 2), entry.id == id else { throw SettingsError(message: "Unsupported History entry \(id).") }
        if let video = entry.video { try video.validate() }
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
                var entry = try read(id)
                if files.fileExists(atPath: child.appendingPathComponent("deleted").path) { continue }
                if entry.video != nil {
                    if (try? validatedMovieURL(entry)) == nil {
                        entry.unavailable = true
                        warnings.append("History video \(id) is unavailable.")
                    }
                    entries.append(entry)
                    continue
                }
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
        if let video = entry.video { return folder(entry.id).appendingPathComponent(video.thumbnail) }
        return folder(entry.id).appendingPathComponent("\(entry.revision.uuidString)-\(name).png")
    }

    @discardableResult
    func commit(document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String = "",
                id: UUID? = nil, now: Date = Date()) throws -> HistoryEntry {
        let previous = try id.map(read)
        guard previous?.video == nil else { throw SettingsError(message: "Videos cannot be edited as screenshots.") }
        if var previous, previous.snapshot == document.snapshot, previous.schema == 1 {
            previous.schema = 2
            try JSONEncoder().encode(previous).write(to: metadata(previous.id), options: .atomic)
            return previous
        }
        if let previous, previous.snapshot == document.snapshot, previous.schema == 2 { return previous }
        guard document.scale.isFinite, document.scale > 0,
              let preview = AnnotationRenderer.export(document),
              let previewData = ImageEncoding.data(preview, scale: document.scale, type: .png),
              let thumbnail = Self.thumbnail(preview),
              let thumbnailData = ImageEncoding.data(thumbnail, scale: 1, type: .png) else {
            throw SettingsError(message: "Could not prepare History image.")
        }
        let entry = HistoryEntry(schema: 2, id: previous?.id ?? UUID(), revision: UUID(), createdAt: previous?.createdAt ?? now,
            modifiedAt: now, scale: document.scale, label: previous?.label ?? label,
            windowTitle: previous?.windowTitle ?? windowTitle, snapshot: document.snapshot, undo: undo)
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
        guard entry.video == nil else { throw SettingsError(message: "Videos open in the default player.") }
        let image = try Self.image(at: folder(id).appendingPathComponent("original.png"))
        guard entry.scale.isFinite, entry.scale > 0 else { throw SettingsError(message: "Invalid History image scale.") }
        var document = EditDocument(image: image, scale: entry.scale)
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
               let entry = try? read(id), entry.video == nil, entry.revision == revision else { return false }
        var indexed = entry
        indexed.schema = 2
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

    func finishDeletions(holding: Set<UUID> = []) throws {
        for id in deleted where !holding.contains(id) {
            if files.fileExists(atPath: folder(id).path) { try files.removeItem(at: folder(id)) }
        }
        deleted = deleted.filter { holding.contains($0) }
    }

    /// Called on startup only: interrupted deletions and orphan revision files are not recoverable.
    func recover() throws {
        if files.fileExists(atPath: stagingURL.path) { try files.removeItem(at: stagingURL) }
        _ = try entries()
        for directory in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            // Unknown schemas are not ours to interpret, even if a future version
            // left a deletion marker. Explicit Clear is the only broad removal.
            if files.fileExists(atPath: metadata(id).path), (try? read(id)) == nil { continue }
            if files.fileExists(atPath: directory.appendingPathComponent("deleted").path) {
                try files.removeItem(at: directory)
            } else if !files.fileExists(atPath: metadata(id).path) {
                try files.removeItem(at: directory)
            } else if let entry = try? read(id) {
                let keep: Set<String> = entry.video.map { ["entry.json", $0.movie, $0.thumbnail] }
                    ?? ["entry.json", "original.png", asset(entry, "preview").lastPathComponent, asset(entry, "thumbnail").lastPathComponent]
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

    var stagingURL: URL { url.deletingLastPathComponent().appendingPathComponent("RecordingSessions", isDirectory: true) }

    func stageVideo() throws -> URL {
        let directory = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The recorder validates the movie before this disk-only transaction. Failed
    /// publication leaves staging owned by the active session for completed-file rescue.
    func publishVideo(staging: URL, video: HistoryVideo, label: String, windowTitle: String = "", now: Date = Date()) throws -> HistoryEntry {
        try video.validate()
        guard staging.deletingLastPathComponent().standardizedFileURL == stagingURL.standardizedFileURL,
              UUID(uuidString: staging.lastPathComponent) != nil else { throw SettingsError(message: "Invalid recording staging directory.") }
        for name in [video.movie, video.thumbnail] {
            let file = staging.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw SettingsError(message: "Recording asset is unavailable.")
            }
        }
        let entry = HistoryEntry(schema: 2, id: UUID(), revision: UUID(), createdAt: now, modifiedAt: now,
            scale: video.scale, label: label, windowTitle: windowTitle,
            snapshot: EditSnapshot(annotations: [], crop: nil), undo: [], video: video)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
        try files.moveItem(at: staging, to: folder(entry.id))
        return entry
    }

    func movieURL(_ entry: HistoryEntry) throws -> URL {
        let current = try read(entry.id)
        guard let video = current.video, current.revision == entry.revision, current.video == entry.video,
              !files.fileExists(atPath: folder(entry.id).appendingPathComponent("deleted").path) else {
            throw SettingsError(message: "History video is unavailable.")
        }
        try video.validate()
        let movie = folder(entry.id).appendingPathComponent(video.movie)
        let values = try movie.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw SettingsError(message: "History video is unavailable.")
        }
        return movie
    }

    /// The caller obtained collision approval from NSSavePanel. Copy to a hidden
    /// sibling first; rename publishes one complete file, including replacement.
    /// The source and every other private History destination are never writable exports.
    func exportVideo(_ entry: HistoryEntry, to destination: URL,
                     cancelled: () -> Bool = { false },
                     copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        let source = try movieURL(entry)
        try exportMovie(source, to: destination, cancelled: cancelled, copy: copy)
    }

    func exportCompletedVideo(_ source: URL, to destination: URL,
                              cancelled: () -> Bool = { false },
                              copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        let directory = source.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == stagingURL.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil,
              source.pathExtension == "mp4",
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw SettingsError(message: "Completed recording is outside its owned session.")
        }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw SettingsError(message: "Completed recording is unavailable.")
        }
        try exportMovie(source, to: destination, cancelled: cancelled, copy: copy)
    }

    private func exportMovie(_ source: URL, to destination: URL, cancelled: () -> Bool,
                             copy: (URL, URL) throws -> Void) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let owned = url.resolvingSymlinksInPath().standardizedFileURL.path
        let sessions = stagingURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination.isFileURL, target.path != owned, !target.path.hasPrefix(owned + "/"),
              target.path != sessions, !target.path.hasPrefix(sessions + "/") else {
            throw SettingsError(message: "Save As must use a location outside private History.")
        }
        let sourceID = try source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let sourceID, let targetID, sourceID.isEqual(targetID) {
            throw SettingsError(message: "Save As cannot overwrite the private original.")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".vishot-export-\(UUID().uuidString).mp4")
        defer { try? files.removeItem(at: temporary) }
        guard !cancelled() else { throw CancellationError() }
        try copy(source, temporary)
        guard !cancelled() else { throw CancellationError() }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Called only on the disk worker. Metadata alone cannot establish that a retained
    /// movie is still playable after restart or external damage.
    func validatedMovieURL(_ entry: HistoryEntry) throws -> URL {
        let movie = try movieURL(entry)
        let video = entry.video!
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        Task.detached {
            do {
                try await VideoRecorder.validateMovie(at: movie, width: video.width, height: video.height)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
                _ = try await generator.image(at: .zero)
                result = .success(())
            } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        try result.get()
        return movie
    }
}
