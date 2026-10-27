import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Validates the actual PNG, then publishes complete bytes without replacement.
/// All destination decisions belong to the caller process, never the app.
public enum AgentCaptureOutput {
    public static func save(_ image: AgentCapturedImage, in workspace: URL) throws -> AgentCaptureFile {
        guard image.width > 0, image.height > 0, image.width <= 32768, image.height <= 32768,
              image.width <= 64_000_000 / image.height,
              let source = CGImageSourceCreateWithData(image.png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == image.width,
              properties[kCGImagePropertyPixelHeight] as? Int == image.height,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              decoded.width == image.width, decoded.height == image.height else {
            throw AgentFailure(.encodingFailed, "The service did not return a complete PNG with matching pixel dimensions.")
        }
        let folder = workspace.appendingPathComponent(".vishot", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Open the directory itself; refuse symlinks so output remains in this workspace.
            let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(directory) }
            let token = UUID().uuidString.lowercased()
            let temporary = ".capture-\(token).tmp"
            let name = "window-\(image.target.id)-\(token).png"
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            defer { close(fd); unlinkat(directory, temporary, 0) }
            try image.png.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
            // Hard-link publication is atomic and fails rather than replacing any file.
            guard linkat(directory, temporary, directory, name, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return AgentCaptureFile(path: folder.appendingPathComponent(name).path, target: image.target,
                                    width: image.width, height: image.height)
        } catch {
            throw AgentFailure(.outputWriteFailed, "Could not write a new PNG in \(folder.path). Check directory permissions and available disk space. No clipboard fallback was used.")
        }
    }
}
