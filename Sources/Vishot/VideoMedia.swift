import Foundation
import CoreMedia

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
}

/// ScreenCaptureKit presentation timestamps use the host clock. Keep rational time
/// throughout; dropped frames do not compress the movie's timeline.
struct VideoTimeline {
    private(set) var origin: CMTime?
    private(set) var last: CMTime?
    mutating func admit(_ host: CMTime) -> CMTime? {
        guard host.isNumeric, host >= .zero, last.map({ host > $0 }) ?? true else { return nil }
        if origin == nil { origin = host }
        last = host
        return host - origin!
    }
    func endpoint(host: CMTime) -> CMTime? {
        guard let origin, let last, host.isNumeric else { return nil }
        return max(host - origin, last - origin + CMTime(value: 1, timescale: 600))
    }
}

/// Admission is closed synchronously at Stop, before queued media work drains.
final class VideoIntake {
    private let lock = NSLock()
    private var pending = 0
    private var cutoff: CMTime?
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
