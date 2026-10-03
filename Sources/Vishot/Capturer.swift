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

    func capture(_ target: CaptureTarget) {
        let task = contentTask ?? Self.loadContent()
        contentTask = nil
        Task { @MainActor in
            do {
                let content = try await task.value
                switch target.kind {
                case .window(let windowID), .element(let windowID, _):
                    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                        NSSound.beep()
                        return
                    }
                    var crop: (element: CGRect, window: CGRect)?
                    // The window's frame now, in case it moved since the catalog was read.
                    if case .element(_, let rect) = target.kind { crop = (rect, window.frame) }
                    try await capture(filter: SCContentFilter(desktopIndependentWindow: window), crop: crop)

                case .display(let displayID):
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        NSSound.beep()
                        return
                    }
                    let ownPID = ProcessInfo.processInfo.processIdentifier
                    let own = content.applications.filter { $0.processID == ownPID }
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    try await capture(filter: filter, crop: nil)
                }
            } catch {
                NSLog("Vishot capture failed: \(error)")
                NSSound.beep()
            }
        }
    }

    /// `crop` is an element rect and the frame of the window being captured, both in points.
    @MainActor
    private func capture(filter: SCContentFilter, crop: (element: CGRect, window: CGRect)?) async throws {
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if let crop {
            let size = CGSize(width: image.width, height: image.height)
            guard let rect = Self.cropRect(for: crop.element, in: crop.window, scale: scale, imageSize: size),
                  let cropped = image.cropping(to: rect)
            else {
                NSSound.beep()
                return
            }
            image = cropped
        }
        copyToPasteboard(image, scale: scale)
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

    /// Pixel rect of `element` inside a capture of the window at `windowFrame`. Both are in points,
    /// in CoreGraphics global space.
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
