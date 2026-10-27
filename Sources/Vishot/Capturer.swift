import AppKit
import VishotRendering
import ScreenCaptureKit
import UniformTypeIdentifiers
import VishotConfiguration

/// A captured image and where its content was on screen, in CoreGraphics global space.
struct Capture {
    let image: CGImage
    /// Pixels per point.
    let scale: CGFloat
    let frame: CGRect
    var initialCrop: CGRect? = nil
}

final class Capturer {
    private var contentTask: Task<SCShareableContent, Error>?
    /// Must stay alive until the clipboard is taken over, so images can be encoded on paste.
    private var provider: ImageProvider?

    /// SCShareableContent can take tens of milliseconds. Starting it when the overlay opens
    /// hides that cost behind the time you spend choosing a window.
    func prefetch() {
        contentTask = Self.loadContent()
    }

    /// Freezes the visible display for Copy and Edit, retaining the target as a crop.
    /// Vishot's own windows are excluded; overlapping apps remain in the source.
    @MainActor
    func frozenSource(for target: CaptureTarget) async -> Capture? {
        let task = contentTask ?? Self.loadContent()
        contentTask = nil
        do {
            let content = try await excludingOwnApplication(from: task)
            guard let selection = EditArea.displaySelection(for: target.frame, displays: content.displays.map(\.frame)) else { return nil }
            let display = content.displays[selection.index]
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            return try await capture(filter: filter, frame: display.frame, crop: selection.crop)
        } catch {
            NSLog("Vishot frozen source capture failed: \(error)")
            return nil
        }
    }

    /// Retains all native-scale display pixels; `crop` is in image-space points.
    @MainActor
    private func capture(filter: SCContentFilter, frame: CGRect, crop: CGRect) async throws -> Capture {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Capture(image: image, scale: scale, frame: frame, initialCrop: crop)
    }

    /// Puts the image on the clipboard. Encoding waits until something pastes.
    func copy(_ image: CGImage, scale: CGFloat, output: OutputStyle) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let provider = ImageProvider(output: ImageOutput(image: image, scale: scale, output: output))
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pasteboard.writeObjects([item])
        self.provider = provider
    }

    /// Writes a PNG in the background. If that fails the image goes to the clipboard, so it isn't lost.
    func save(_ image: CGImage, scale: CGFloat, to url: URL, output style: OutputStyle, completion: (() -> Void)? = nil) {
        let output = ImageOutput(image: image, scale: scale, output: style)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let data = output.data(type: .png) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
                DispatchQueue.main.async { completion?() }
            } catch {
                NSLog("Vishot save to \(url.path) failed: \(error)")
                DispatchQueue.main.async {
                    NSSound.beep()
                    self.copy(image, scale: scale, output: style)
                    completion?()
                }
            }
        }
    }

    /// Prefetch may finish before our panels are on screen. Never build a display filter from
    /// that snapshot unless it contains our app: an empty exclusion list captures the picker.
    @MainActor
    private func excludingOwnApplication(from task: Task<SCShareableContent, Error>) async throws -> SCShareableContent {
        let pid = ProcessInfo.processInfo.processIdentifier
        var content = try await task.value
        if !content.applications.contains(where: { $0.processID == pid }) {
            content = try await Self.loadContent().value
        }
        guard content.applications.contains(where: { $0.processID == pid }) else {
            throw SettingsError(message: "Could not exclude Vishot from screen capture.")
        }
        return content
    }

    private static func loadContent() -> Task<SCShareableContent, Error> {
        // Include our prebuilt, currently offscreen panels in the catalog too.
        Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
    }
}

/// Encodes the image only when another app asks for it. Encoding a Retina screenshot to PNG or TIFF
/// takes ~100 ms, so the copy itself returns immediately. The watermark is drawn then too, once for
/// both types.
private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
    private let output: ImageOutput

    init(output: ImageOutput) {
        self.output = output
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = output.data(type: type == .png ? .png : .tiff) else { return }
        item.setData(data, forType: type)
    }
}

/// Immutable output preferences, with pixels prepared only on paste/save.
struct OutputStyle {
    let watermark: Bool
    let style: WatermarkStyle
}

final class ImageOutput {
    private let image: CGImage
    private let scale: CGFloat
    private let output: OutputStyle
    private lazy var marked = output.watermark ? Watermark.apply(to: image, scale: scale, style: output.style) : image

    init(image: CGImage, scale: CGFloat, output: OutputStyle) {
        self.image = image
        self.scale = scale
        self.output = output
    }

    func data(type: UTType) -> Data? { ImageEncoding.data(marked, scale: scale, type: type) }
}
