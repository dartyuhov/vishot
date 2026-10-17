import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    var watermark = true

    /// SCShareableContent can take tens of milliseconds. Starting it when the overlay opens
    /// hides that cost behind the time you spend choosing a window.
    func prefetch() {
        contentTask = Self.loadContent()
    }

    /// Captures `target` and copies it. The ↵ path: runs after the overlay hides.
    func capture(_ target: CaptureTarget) {
        let watermark = watermark
        Task { @MainActor in
            guard let capture = await image(for: target) else {
                NSSound.beep()
                return
            }
            copy(capture.image, scale: capture.scale, watermark: watermark)
        }
    }

    /// Captures `target`, or returns nil if it is gone or the capture fails. Vishot's own windows are
    /// never in the image, so this can run with the overlay up.
    @MainActor
    func editorImage(for target: CaptureTarget) async -> Capture? {
        let task = contentTask ?? Self.loadContent()
        contentTask = nil
        do {
            let content = try await task.value
            guard let selection = EditArea.displaySelection(for: target.frame, displays: content.displays.map(\.frame)) else { return nil }
            let display = content.displays[selection.index]
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            guard var result = try await capture(filter: filter, frame: display.frame, crop: nil) else { return nil }
            result.initialCrop = selection.crop
            return result
        } catch {
            NSLog("Vishot editor capture failed: \(error)")
            return nil
        }
    }

    @MainActor
    func image(for target: CaptureTarget) async -> Capture? {
        let task = contentTask ?? Self.loadContent()
        contentTask = nil
        do {
            let content = try await task.value
            switch target.kind {
            case .window(let windowID), .element(let windowID, _):
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
                var crop: (rect: CGRect, content: CGRect)?
                // The window's frame now, in case it moved since the catalog was read.
                if case .element(_, let rect) = target.kind { crop = (rect, window.frame) }
                return try await capture(filter: SCContentFilter(desktopIndependentWindow: window), frame: window.frame, crop: crop)

            case .display(let displayID), .region(let displayID, _):
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let own = content.applications.filter { $0.processID == ownPID }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                var crop: (rect: CGRect, content: CGRect)?
                if case .region(_, let rect) = target.kind { crop = (rect, display.frame) }
                return try await capture(filter: filter, frame: display.frame, crop: crop)
            }
        } catch {
            NSLog("Vishot capture failed: \(error)")
            return nil
        }
    }

    /// `frame` is where the captured content is, in CoreGraphics global space. `crop` is an element or
    /// region rect and the frame of the window or display being captured, both in points.
    @MainActor
    private func capture(filter: SCContentFilter, frame: CGRect, crop: (rect: CGRect, content: CGRect)?) async throws -> Capture? {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let crop else { return Capture(image: image, scale: scale, frame: frame) }
        let size = CGSize(width: image.width, height: image.height)
        guard let rect = Self.cropRect(for: crop.rect, in: crop.content, scale: scale, imageSize: size),
              let cropped = image.cropping(to: rect)
        else { return nil }
        let croppedFrame = CGRect(
            x: crop.content.minX + rect.minX / scale,
            y: crop.content.minY + rect.minY / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
        return Capture(image: cropped, scale: scale, frame: croppedFrame)
    }

    /// Puts the image on the clipboard. Encoding waits until something pastes.
    func copy(_ image: CGImage, scale: CGFloat, watermark: Bool? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let provider = ImageProvider(output: ImageOutput(image: image, scale: scale, watermark: watermark ?? self.watermark))
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pasteboard.writeObjects([item])
        self.provider = provider
    }

    /// Writes a PNG in the background. If that fails the image goes to the clipboard, so it isn't lost.
    func save(_ image: CGImage, scale: CGFloat, to url: URL, watermark: Bool? = nil) {
        let output = ImageOutput(image: image, scale: scale, watermark: watermark ?? self.watermark)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let data = output.data(type: .png) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Vishot save to \(url.path) failed: \(error)")
                DispatchQueue.main.async {
                    NSSound.beep()
                    self.copy(image, scale: scale, watermark: output.watermark)
                }
            }
        }
    }

    /// Pixel rect of `element` inside a capture of the window at `windowFrame`, or of a region inside a
    /// capture of its display. Both are in points, in CoreGraphics global space.
    /// Returns nil when the element is entirely outside the image.
    static func cropRect(for element: CGRect, in windowFrame: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect? {
        let pixels = CGRect(
            x: (element.minX - windowFrame.minX) * scale,
            y: (element.minY - windowFrame.minY) * scale,
            width: element.width * scale,
            height: element.height * scale
        ).integral
        let crop = pixels.intersection(CGRect(origin: .zero, size: imageSize))
        return crop.isEmpty ? nil : crop
    }

    private static func loadContent() -> Task<SCShareableContent, Error> {
        Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
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
final class ImageOutput {
    private let image: CGImage
    private let scale: CGFloat
    let watermark: Bool
    private lazy var marked = watermark ? Watermark.apply(to: image, scale: scale) : image

    init(image: CGImage, scale: CGFloat, watermark: Bool) {
        self.image = image
        self.scale = scale
        self.watermark = watermark
    }

    func data(type: UTType) -> Data? { ImageEncoding.data(marked, scale: scale, type: type) }
}

enum ImageEncoding {
    /// Encodes `image`, tagged with its DPI so Retina captures open and paste at their on-screen size
    /// instead of 2x.
    static func data(_ image: CGImage, scale: CGFloat, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
