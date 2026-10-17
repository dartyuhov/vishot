import AppKit

/// Copy completion owns the requested pixels and editable state independently of the UI session.
/// All calls are on the main thread; history persistence remains on HistoryLibrary's worker.
final class ScreenshotCompletion {
    enum Presentation: Equatable {
        case close
        case history(UUID)
    }

    private let history: HistoryLibrary
    private let copyImage: (CGImage, CGFloat, Bool) -> Void

    init(history: HistoryLibrary, copy: @escaping (CGImage, CGFloat, Bool) -> Void) {
        self.history = history
        self.copyImage = copy
    }

    func prepare(document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String = "",
                 id: UUID? = nil, session: Int, watermark: Bool, exported: CGImage? = nil) -> Request? {
        guard let image = exported ?? AnnotationRenderer.export(document) else { return nil }
        return Request(history: history, copy: copyImage, document: document, undo: undo, label: label,
            windowTitle: windowTitle, id: id, session: session, watermark: watermark, image: image)
    }

    final class Request {
        private let history: HistoryLibrary
        private let copyImage: (CGImage, CGFloat, Bool) -> Void
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

        fileprivate init(history: HistoryLibrary, copy: @escaping (CGImage, CGFloat, Bool) -> Void,
                         document: EditDocument, undo: [EditSnapshot], label: String, windowTitle: String,
                         id: UUID?, session: Int, watermark: Bool, image: CGImage) {
            self.history = history
            self.copyImage = copy
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
            guard !finished else { return nil }
            finished = true
            copyImage(image, document.scale, watermark)
            history.commit(document: document, undo: undo, label: label, windowTitle: windowTitle,
                id: id, recording: recording)
            if let id { history.release(id) }
            guard session == currentSession else { return nil }
            return id.map(Presentation.history) ?? .close
        }

        func cancel() {
            guard !finished else { return }
            finished = true
            if let id { history.release(id) }
        }
    }
}
