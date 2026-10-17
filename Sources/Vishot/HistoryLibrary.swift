import AppKit

/// A browser request can become obsolete before its turn on the serial disk queue.
final class HistoryImageRequest {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Main-thread facade. Disk/encoding work is serialized; one OCR request runs at a time on a
/// separate queue, so recognition never holds up publication or browser reads.
final class HistoryLibrary {
    private let store: HistoryStore
    private let worker = DispatchQueue(label: "dev.vishot.history", qos: .utility)
    private let browserReader = DispatchQueue(label: "dev.vishot.history.images", qos: .userInitiated)
    private let ocr = DispatchQueue(label: "dev.vishot.history.ocr", qos: .utility)
    private var timer: Timer?
    private var indexing: Set<String> = [] // worker queue only
    private var held: [UUID: Int] = [:] // worker queue only; overlapping output/editor holds are independent
    private(set) var entries: [HistoryEntry] = []
    private(set) var error: String?
    private enum Operation: Equatable {
        case startup, cleanup, commit(UUID?), delete(UUID), undoDelete, finishDeletions, clear
        case index(UUID), load(UUID), preview(UUID), publication
    }
    // A new-capture commit (nil ID) recovers a previous new-capture failure. Updates recover
    // only that entry's commit failure, including an unchanged retry of its committed state.
    // Main queue only. Recovery removes exactly its operation's failure; publications only
    // refresh directory warnings. Keep every unresolved failure, newest first in the status.
    private var failures: [(Operation, String)] = []
    private var warning: String?
    private(set) var diskUsage: Int64 = 0
    var onChange: (() -> Void)?
    var retention = HistoryRetention.sevenDays {
        didSet { if oldValue != retention { cleanup() } }
    }

    init(store: HistoryStore = HistoryStore()) { self.store = store }
    deinit { timer?.invalidate() }

    func start() {
        perform(.startup) { try self.store.recover() }
        cleanup()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.cleanup() }
    }

    func cleanup() {
        let policy = retention
        perform(.cleanup) { try self.store.cleanup(retention: policy, holding: Set(self.held.keys)) }
    }

    func hold(_ id: UUID) { worker.async { self.held[id, default: 0] += 1 } }
    func release(_ id: UUID) {
        worker.async {
            let count = self.held[id, default: 0]
            if count <= 1 { self.held.removeValue(forKey: id) } else { self.held[id] = count - 1 }
        }
        cleanup()
    }

    func commit(document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String = "", id: UUID? = nil,
                recording: Bool? = nil) {
        guard id != nil || (recording ?? (retention != .off)) else { return }
        let now = Date()
        perform(.commit(id)) {
            try self.store.commit(document: document, undo: undo, label: label, windowTitle: windowTitle, id: id, now: now)
        }
    }

    func load(_ id: UUID, completion: @escaping (HistoryDocument?) -> Void) {
        worker.async {
            do {
                let document = try self.store.load(id)
                self.recovered(.load(id))
                DispatchQueue.main.async { completion(document) }
            } catch { self.report(error, operation: .load(id)); DispatchQueue.main.async { completion(nil) } }
        }
    }

    @discardableResult
    func image(_ entry: HistoryEntry, thumbnail: Bool, maxPixelSize: Int? = nil,
               completion: @escaping (CGImage?) -> Void) -> HistoryImageRequest {
        let request = HistoryImageRequest()
        browserReader.async {
            guard !request.isCancelled else { return }
            do {
                let image = try self.store.preview(entry, thumbnail: thumbnail, maxPixelSize: thumbnail ? 320 : maxPixelSize)
                if !request.isCancelled { self.recovered(.preview(entry.id)) }
                DispatchQueue.main.async { if !request.isCancelled { completion(image) } }
            } catch {
                if !request.isCancelled { self.report(error, operation: .preview(entry.id)) }
                DispatchQueue.main.async { if !request.isCancelled { completion(nil) } }
            }
        }
        return request
    }

    func delete(_ id: UUID, completion: @escaping (Bool) -> Void = { _ in }) {
        worker.async {
            do {
                try self.store.delete(id)
                self.recovered(.delete(id))
                do { try self.publish() } catch { self.report(error, operation: .publication) }
                DispatchQueue.main.async { completion(true) }
            } catch { self.report(error, operation: .delete(id)); DispatchQueue.main.async { completion(false) } }
        }
    }
    func undoDelete(completion: @escaping (UUID?) -> Void) {
        worker.async {
            do {
                let id = try self.store.undoDelete()
                if id != nil { self.recovered(.undoDelete) }
                do { try self.publish() } catch { self.report(error, operation: .publication) }
                DispatchQueue.main.async { completion(id) }
            } catch { self.report(error, operation: .undoDelete); DispatchQueue.main.async { completion(nil) } }
        }
    }
    func finishSession() { perform(.finishDeletions) { try self.store.finishDeletions() } }
    func clear() { perform(.clear) { try self.store.clear() } }

    private func perform(_ key: Operation, _ operation: @escaping () throws -> Void) {
        worker.async {
            do { try operation() } catch { self.report(error, operation: key); return }
            self.recovered(key)
            do { try self.publish() } catch { self.report(error, operation: .publication) }
        }
    }

    private func publish() throws {
        let entries = try store.entries()
        let usage = try store.diskUsage()
        let warning = store.warnings.first
        DispatchQueue.main.async {
            self.entries = entries
            self.diskUsage = usage
            self.warning = warning
            self.failures.removeAll { $0.0 == .publication }
            self.updateError()
        }
        // Queue only one job ahead. Completion schedules the next from fresh committed metadata.
        guard indexing.isEmpty, let entry = entries.first(where: { $0.recognizedText == nil }) else { return }
        scheduleIndex(entry)
    }

    private var failedIndex: Set<UUID> = []
    private func scheduleIndex(_ entry: HistoryEntry) {
        guard !failedIndex.contains(entry.revision) else {
            if let next = try? store.entries().first(where: { $0.recognizedText == nil && !failedIndex.contains($0.revision) }) { scheduleIndex(next) }
            return
        }
        let key = entry.revision.uuidString
        indexing.insert(key)
        do {
            let image = try store.preview(entry)
            ocr.async {
                let result = Result { try HistorySearch.recognize(image) }
                self.worker.async {
                    self.indexing.remove(key)
                    do {
                        switch result {
                        case .success(let text):
                            if try self.store.index(entry.id, revision: entry.revision, text: text) {
                                self.recovered(.index(entry.id))
                            }
                        case .failure:
                            self.failedIndex.insert(entry.revision)
                        }
                        do { try self.publish() } catch { self.report(error, operation: .publication) }
                    } catch { self.failedIndex.insert(entry.revision); self.report(error, operation: .index(entry.id)) }
                }
            }
        } catch { indexing.remove(key); failedIndex.insert(entry.revision); report(error, operation: .index(entry.id)) }
    }

    private func report(_ error: Error, operation: Operation) {
        DispatchQueue.main.async {
            self.failures.removeAll { $0.0 == operation }
            self.failures.append((operation, "History: \(error.localizedDescription)"))
            self.updateError()
        }
    }

    private func recovered(_ operation: Operation) {
        DispatchQueue.main.async {
            guard self.failures.contains(where: { $0.0 == operation }) else { return }
            self.failures.removeAll { $0.0 == operation }
            self.updateError()
        }
    }

    private func updateError() {
        error = failures.reversed().map { $0.1 }.joined(separator: "\n")
        if failures.isEmpty { error = warning }
        onChange?()
    }
}
