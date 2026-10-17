import AppKit

/// Output completion owns the requested pixels and editable state independently of the UI session.
/// All calls are on the main thread; history persistence remains on HistoryLibrary's worker.
final class ScreenshotCompletion {
    typealias Save = (CGImage, CGFloat, URL, Bool, @escaping () -> Void) -> Void
    enum Presentation: Equatable {
        case close
        case history(UUID)
    }

    private let history: HistoryLibrary
    private let copyImage: (CGImage, CGFloat, Bool) -> Void
    private let saveImage: Save

    init(history: HistoryLibrary,
         save: Save? = nil,
         copy: @escaping (CGImage, CGFloat, Bool) -> Void) {
        self.history = history
        self.copyImage = copy
        let capturer = Capturer()
        self.saveImage = save ?? { capturer.save($0, scale: $1, to: $2, watermark: $3, completion: $4) }
    }

    func prepare(document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String = "",
                 id: UUID? = nil, session: Int, watermark: Bool, exported: CGImage? = nil) -> Request? {
        guard let image = exported ?? AnnotationRenderer.export(document) else { return nil }
        return Request(history: history, copy: copyImage, save: saveImage, document: document, undo: undo, label: label,
            windowTitle: windowTitle, id: id, session: session, watermark: watermark, image: image)
    }

    final class Request {
        private let history: HistoryLibrary
        private let copyImage: (CGImage, CGFloat, Bool) -> Void
        private let saveImage: Save
        private let document: EditDocument
        private let undo: [EditSnapshot]
        private let label: String
        private let windowTitle: String
        private let id: UUID?
        private let session: Int
        private let watermark: Bool
        private let recording: Bool
        private let image: CGImage
        private var finished = false
        private var saving = false

        fileprivate init(history: HistoryLibrary, copy: @escaping (CGImage, CGFloat, Bool) -> Void, save: @escaping Save,
                         document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String,
                         id: UUID?, session: Int, watermark: Bool, image: CGImage) {
            self.history = history
            self.copyImage = copy
            self.saveImage = save
            self.document = document
            self.undo = undo
            self.label = label
            self.windowTitle = windowTitle
            self.id = id
            self.session = session
            self.watermark = watermark
            self.recording = history.retention != .off
            self.image = image
            // Independent from the editor's hold: closing/replacing its session cannot expire
            // this output before its queued history commit.
            if let id { history.hold(id) }
        }

        deinit { cancel() }

        /// A valid requested output still copies after replacement, but has no stale UI outcome.
        @discardableResult
        func copy(currentSession: Int) -> Presentation? {
            guard !finished, !saving else { return nil }
            finished = true
            copyImage(image, document.scale, watermark)
            return complete(currentSession: currentSession)
        }

        /// Native cancellation abandons only this output, leaving the editor session intact.
        func saveAs(to url: URL?, currentSession: @escaping () -> Int,
                    present: @escaping (Presentation?) -> Void) {
            guard let url else { cancel(); return }
            save(to: url, currentSession: currentSession, present: present)
        }

        /// The adapter completes after either the file write or its clipboard fallback.
        /// Retain the request until then, even when its originating UI has gone away.
        func save(to url: URL, copying: Bool = false, currentSession: @escaping () -> Int,
                  present: @escaping (Presentation?) -> Void) {
            guard !finished, !saving else { return }
            saving = true
            if copying {
                finished = true
                copyImage(image, document.scale, watermark)
                present(complete(currentSession: currentSession()))
            }
            saveImage(image, document.scale, url, watermark) { [self] in
                guard !finished else { return }
                present(complete(currentSession: currentSession()))
            }
        }

        private func complete(currentSession: Int) -> Presentation? {
            finished = true
            history.commit(document: document, undo: undo, label: label, windowTitle: windowTitle,
                id: id, recording: recording)
            if let id { history.release(id) }
            guard session == currentSession else { return nil }
            return id.map(Presentation.history) ?? .close
        }

        func cancel() {
            guard !finished, !saving else { return }
            finished = true
            if let id { history.release(id) }
        }
    }
}
