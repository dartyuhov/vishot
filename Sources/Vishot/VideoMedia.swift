import Foundation
import VishotConfiguration
import CoreMedia
import CoreImage

struct VideoDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
}

struct VideoRectangle: Equatable {
    let display: VideoDisplay
    let rect: CGRect
    var sourceRect: CGRect { rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
}

/// Window identity is used only before startup. Element geometry is cached once,
/// relative to its selected parent window; resolving never traverses AX.
struct VideoSelection {
    private enum Source {
        case window(UInt32)
        case element(UInt32, CGRect)
        case display(UInt32)
        case region(UInt32, CGRect)
    }
    private let source: Source
    var windowID: UInt32? {
        switch source {
        case .window(let id), .element(let id, _): return id
        default: return nil
        }
    }

    init(target: CaptureTarget, windowFrame: CGRect?) throws {
        switch target.kind {
        case .window(let id): source = .window(id)
        case .element(let id, let rect):
            guard let windowFrame, Self.valid(windowFrame), Self.valid(rect) else {
                throw SettingsError(message: "The selected element's window bounds are unavailable.")
            }
            source = .element(id, rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY))
        case .display(let id): source = .display(id)
        case .region(let id, let rect): source = .region(id, rect)
        }
    }

    func resolve(displays: [VideoDisplay], windowFrame: CGRect?) throws -> VideoRectangle {
        let rect: CGRect
        let candidates: [VideoDisplay]
        switch source {
        case .window, .element:
            guard let windowFrame, Self.valid(windowFrame) else {
                throw SettingsError(message: "The selected window is unavailable.")
            }
            if case .element(_, let relative) = source {
                rect = relative.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
            } else { rect = windowFrame }
            candidates = displays
        case .display(let id):
            candidates = displays.filter { $0.id == id }
            rect = candidates.first?.frame ?? .null
        case .region(let id, let region):
            candidates = displays.filter { $0.id == id }
            rect = region
        }
        guard Self.valid(rect) else { throw SettingsError(message: "The recording rectangle is unavailable.") }
        var best: VideoRectangle?
        var area: CGFloat = 0
        for display in candidates where Self.valid(display.frame) && display.scale.isFinite && display.scale > 0 {
            let clipped = rect.intersection(display.frame)
            guard Self.valid(clipped), clipped.width * clipped.height > area else { continue }
            area = clipped.width * clipped.height
            best = VideoRectangle(display: display, rect: clipped)
        }
        guard let best else { throw SettingsError(message: "The recording rectangle has no visible display intersection.") }
        return best
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

struct VideoCanvas {
    let width: Int
    let height: Int
    let contentSize: CGSize
    init(native: CGSize) throws {
        guard native.width.isFinite, native.height.isFinite, native.width > 0, native.height > 0 else {
            throw SettingsError(message: "Invalid recording dimensions.")
        }
        let fit = min(1, 3840 / native.width, 2160 / native.height)
        contentSize = CGSize(width: native.width * fit, height: native.height * fit)
        width = Int(ceil(contentSize.width / 2)) * 2
        height = Int(ceil(contentSize.height / 2)) * 2
    }
    var bitrate: Int { min(30_000_000, max(2_000_000, Int(Double(width * height) * 3))) }

    /// SCStream's destinationRect has already fitted the picture to this canvas.
    /// Copy the padded surface 1:1 so odd edges and pointer positions stay intact.
    func normalize(_ image: CIImage) -> CIImage {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }
}

/// ScreenCaptureKit presentation timestamps use the host clock. Keep rational time
/// throughout; dropped frames do not compress the movie's timeline.
struct VideoTimeline {
    private(set) var origin: CMTime?
    private(set) var last: CMTime?
    private var nextFrame: CMTime?
    mutating func admit(_ host: CMTime) -> CMTime? {
        guard host.isNumeric, host >= .zero, last.map({ host > $0 }) ?? true else { return nil }
        // Advance a cadence deadline, not last timestamp + interval: rounded or
        // jittery nominal-30 timestamps must not alternate between accept/drop.
        // A bounded 1ms early allowance never accumulates into a faster cadence.
        let interval = CMTime(value: 1, timescale: 30)
        let tolerance = CMTime(value: 1, timescale: 1000)
        if let nextFrame {
            guard host + tolerance >= nextFrame else { return nil }
            // Rebase after a gap; idle time cannot bank catch-up frames.
            self.nextFrame = host > nextFrame + interval ? host + interval : nextFrame + interval
        } else { nextFrame = host + interval }
        if origin == nil { origin = host }
        last = host
        return host - origin!
    }
    func endpoint(host: CMTime) -> CMTime? {
        guard let origin, let last, host.isNumeric else { return nil }
        // Every presented sample occupies at least one nominal frame. For an
        // immediate Stop this adds <1/30s, within A10, instead of advertising 600fps.
        return max(host - origin, last - origin + CMTime(value: 1, timescale: 30))
    }
}

/// Admission is closed synchronously at Stop, before queued media work drains.
final class VideoIntake {
    private let lock = NSLock()
    private var pending = 0
    private var cutoff: CMTime?
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return cutoff != nil }
    func admit(_ time: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard cutoff == nil, pending < 3, time.isNumeric else { return false }
        pending += 1
        return true
    }
    func release() { lock.lock(); pending -= 1; lock.unlock() }
    func close(at time: CMTime) { lock.lock(); if cutoff == nil { cutoff = time }; lock.unlock() }
    func allows(_ time: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cutoff.map { time <= $0 } ?? true
    }
}
