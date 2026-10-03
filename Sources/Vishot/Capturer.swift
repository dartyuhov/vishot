import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

final class Capturer {
    private var contentTask: Task<SCShareableContent, Error>?
    /// Must stay alive until the clipboard is taken over, so images can be encoded on paste.
    private var provider: ImageProvider?

    /// SCShareableContent can take tens of milliseconds. Starting it when the overlay opens
    /// hides that cost behind the time you spend choosing a window.
    func prefetch() {
        contentTask = Self.loadContent()
    }

    func capture(windowID: CGWindowID) {
        let task = contentTask ?? Self.loadContent()
        contentTask = nil
        Task { @MainActor in
            do {
                let content = try await task.value
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    NSSound.beep()
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.captureResolution = .best
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                copyToPasteboard(image, scale: scale)
            } catch {
                NSLog("Vishot capture failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private func copyToPasteboard(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let provider = ImageProvider(image: image, scale: scale)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pasteboard.writeObjects([item])
        self.provider = provider
    }

    private static func loadContent() -> Task<SCShareableContent, Error> {
        Task { try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
    }
}

/// Encodes the image only when another app asks for it. Encoding a Retina screenshot to PNG or TIFF
/// takes ~100 ms, so the copy itself returns immediately.
private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
    private let image: CGImage
    private let scale: CGFloat

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let utType: UTType = type == .png ? .png : .tiff
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else { return }
        // Tag the DPI so Retina captures paste at their on-screen size instead of 2x.
        let dpi = 72 * scale
        let properties = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return }
        item.setData(data as Data, forType: type)
    }
}
