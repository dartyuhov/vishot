import Foundation
import VishotConfiguration

struct HistoryVideo: Codable, Equatable {
    let movie: String
    let thumbnail: String
    let duration: Double
    let width: Int
    let height: Int
    let displayID: UInt32
    let frame: CGRect
    let scale: CGFloat
    var codec = "h264"
    var color = "sdr-srgb-bt709"

    func validate() throws {
        func safe(_ name: String, extension suffix: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
                && (name as NSString).pathExtension == suffix
        }
        guard safe(movie, extension: "mp4"), safe(thumbnail, extension: "png"),
              duration.isFinite, duration > 0, width > 0, height > 0, width <= 3840, height <= 2160,
              width % 2 == 0, height % 2 == 0, scale.isFinite, scale > 0,
              frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, codec == "h264", color == "sdr-srgb-bt709" else {
            throw SettingsError(message: "Invalid History video payload.")
        }
    }
    var durationLabel: String {
        let seconds = Int(duration.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
