import AppKit
import VishotRendering
import VishotConfiguration
import ImageIO
import VishotAgent

/// Local PNG vertical slice. Never calls Capturer, pasteboard, history, or application startup.
enum AnnotationCommand {
    static let maxJSONBytes = 1024 * 1024
    static let maxAnnotations = 256
    static let maxTextBytes = 16 * 1024
    static let maxTotalTextBytes = 256 * 1024

    /// The local execution boundary keeps OS opening injectable without process-global switches.
    static func execute(_ arguments: [String],
                        workspace: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                        resourceDirectory: () throws -> URL? = { nil },
                        styleSnapshot: () throws -> VisualStyle = { try annotationStyleSnapshot() },
                        render: (EditDocument) -> CGImage? = AnnotationRenderer.export,
                        encode: (CGImage, CGFloat) -> Data? = { ImageEncoding.data($0, scale: $1, type: .png) },
                        opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> AgentResponse {
        do {
            let options = try AnnotationArguments(arguments)
            let resources = try resourceDirectory()
            let png = try read(URL(fileURLWithPath: options.input), limit: 90 * 1024 * 1024, code: .invalidImage)
            let input = try decode(png)
            let json: Data
            if let inline = options.inlineJSON {
                guard inline.utf8.count <= maxJSONBytes else {
                    throw AgentFailure(.invalidAnnotations, "Annotation JSON must be at most 1 MiB.")
                }
                json = Data(inline.utf8)
            } else {
                json = try read(URL(fileURLWithPath: options.jsonFile!), limit: maxJSONBytes, code: .invalidAnnotations)
            }
            // Fonts must be registered before any theme factory resolves its annotation font.
            if let resources, !Fonts.register(resourceDirectory: resources) {
                throw AgentFailure(.renderingFailed, "Could not register the containing app's bundled fonts. Reinstall the complete Vishot.app and retry.")
            }
            let selection = try styleSnapshot()
            let document = try document(json: json, image: input.image, scale: input.scale, style: selection)
            guard let rendered = render(document) else {
                throw AgentFailure(.renderingFailed, "Could not render the annotation batch.")
            }
            guard let encoded = encode(rendered, input.scale),
                  encoded.count <= 90 * 1024 * 1024 else {
                throw AgentFailure(.encodingFailed, "Could not encode the annotated PNG within the 90 MiB limit.")
            }
            let path = try AgentCaptureOutput.publish(png: encoded, width: rendered.width, height: rendered.height,
                prefix: "annotation", in: workspace)
            // Publication has finished (including temporary-file cleanup) before OS handoff.
            let openingStatus = options.open ? (opener(URL(fileURLWithPath: path)) ? "accepted" : "failed") : "not_requested"
            let openingError: AgentFailure? = openingStatus == "failed" ? AgentFailure(.openingFailed,
                "The annotated PNG was saved at \(path), but macOS did not accept the open request. Open this file manually or check the default application for PNG images in Finder's Get Info.") : nil
            return .annotated(AgentAnnotationFile(path: path, width: rendered.width, height: rendered.height,
                                                      style: selection.rawValue, openingStatus: openingStatus), error: openingError)
        } catch let failure as AgentFailure { return .failure(failure) }
        catch { return .failure(AgentFailure(.renderingFailed, "Could not complete local PNG annotation.")) }
    }

    static func annotationStyleSnapshot(url: URL = AppSettings.defaultURL) throws -> VisualStyle {
        do { return try AppSettings.annotationStyleSnapshot(url: url) }
        catch { throw AgentFailure(.invalidArguments, error.localizedDescription) }
    }

    private static func read(_ url: URL, limit: Int, code: AgentFailure.Code) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= limit else {
                throw AgentFailure(code, "Input exceeds the \(limit)-byte limit.")
            }
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw AgentFailure(code, "Input exceeds the \(limit)-byte limit.") }
            return data
        } catch let failure as AgentFailure { throw failure }
        catch { throw AgentFailure(code, "Could not read the local input file: \(url.path).") }
    }

    private static func decode(_ png: Data) throws -> (image: CGImage, scale: CGFloat) {
        guard let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, width <= 64_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height else {
            throw AgentFailure(.invalidImage, "Input must be one complete PNG, at most 32768 pixels per side and 64 million pixels total (90 MiB encoded).")
        }
        // Missing/invalid/non-square metadata has no usable uniform scale and uses 1x.
        // Valid square DPI outside 9...2304 fails explicitly rather than silently changing sizing.
        // The lower bound caps point-space geometry (and PixelArt cell allocations); the upper
        // bound caps point-based text/strokes at 32x. Pixels are never resized. Allow PNG's
        // pixels/metre rounding (half a unit = 0.0127 DPI) at the supported endpoints.
        var scale: CGFloat = 1
        if let x = properties[kCGImagePropertyDPIWidth] as? Double,
           let y = properties[kCGImagePropertyDPIHeight] as? Double,
           x.isFinite, y.isFinite, x > 0, y > 0,
           abs(x - y) <= 0.02 {
            guard min(x, y) >= 9 - 0.013, max(x, y) <= 2304 + 0.013 else {
                throw AgentFailure(.invalidImage, "Square PNG DPI must be within 9...2304 for bounded annotation rendering.")
            }
            scale = CGFloat(min(2304, max(9, x)) / 72)
        }
        return (image, scale)
    }

    /// Validates the whole parseable batch before creating a document or publishing any output.
    /// Public geometry is pixels/top-left. Text overflow is clipped; marks must fit the image.
    static func document(json: Data, image: CGImage, scale: CGFloat, style: VisualStyle) throws -> EditDocument {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) }
        catch { throw AgentFailure(.invalidJSON, "Malformed JSON. Supply one schemaVersion 1 object with an annotations array.") }
        var problems: [AgentValidationProblem] = []
        func problem(_ field: String, _ reason: String, index: Int? = nil) {
            problems.append(AgentValidationProblem(index: index, field: field, reason: reason))
        }
        guard let batch = value as? [String: Any] else {
            throw AgentFailure(.invalidAnnotations, "Invalid annotation batch.", problems: [
                AgentValidationProblem(field: "$", reason: "Expected an object with schemaVersion and annotations.")])
        }
        for key in batch.keys.sorted() where !["schemaVersion", "annotations"].contains(key) {
            problem(key, "Unknown field; allowed fields: schemaVersion, annotations.")
        }
        if number(batch["schemaVersion"]) != 1 { problem("schemaVersion", "Required supported integer version: 1.") }
        var annotations: [Annotation] = []
        var resolved = AnnotationCatalog.annotation(style.annotationID)
        resolved.snapsTextToGrid = false
        if let items = batch["annotations"] as? [Any] {
            if items.isEmpty || items.count > maxAnnotations {
                problem("annotations", "Expected 1...\(maxAnnotations) annotations.")
            }
            var totalBytes = 0
            // Even oversized batches are bounded by the 1 MiB JSON budget. Inspect every item
            // for identifiable field errors, but never render or measure oversized text.
            for (index, item) in items.enumerated() {
                let path = "annotations[\(index)]"
                guard let fields = item as? [String: Any] else {
                    problem(path, "Expected a text, arrow, or rect annotation object.", index: index); continue
                }
                let before = problems.count
                let type = fields["type"] as? String
                let allowed: [String]
                switch type {
                case "arrow": allowed = ["type", "from", "to", "color"]
                case "rect": allowed = ["type", "x", "y", "width", "height", "color"]
                default: allowed = ["type", "x", "y", "text", "color"]
                }
                for key in fields.keys.sorted() where !allowed.contains(key) {
                    problem(path + "." + key, "Unknown field; allowed fields: \(allowed.joined(separator: ", ")).", index: index)
                }
                if !["text", "arrow", "rect"].contains(type) {
                    problem(path + ".type", "Required supported type: text, arrow, rect.", index: index)
                }
                var color = AnnotationColor.purple
                if let value = fields["color"] {
                    if let name = value as? String, let parsed = AnnotationColor(rawValue: name) { color = parsed }
                    else { problem(path + ".color", "Allowed colors: red, yellow, green, purple, white, black (default purple).", index: index) }
                }
                func coordinate(_ value: Any?, field: String, bound: Int) -> Double? {
                    guard let n = number(value), n >= 0, n < Double(bound) else {
                        problem(path + "." + field, "Expected a finite image-pixel number in [0, \(bound)).", index: index)
                        return nil
                    }
                    return n
                }
                func point(_ key: String) -> CGPoint? {
                    guard let point = fields[key] as? [String: Any] else {
                        problem(path + "." + key, "Required point object with x and y in image pixels.", index: index)
                        return nil
                    }
                    for field in point.keys.sorted() where !["x", "y"].contains(field) {
                        problem(path + "." + key + "." + field, "Unknown point field; allowed fields: x, y.", index: index)
                    }
                    let x = coordinate(point["x"], field: key + ".x", bound: image.width)
                    let y = coordinate(point["y"], field: key + ".y", bound: image.height)
                    guard let x, let y else { return nil }
                    return CGPoint(x: x / scale, y: y / scale)
                }
                var annotation: Annotation?
                switch type {
                case "arrow":
                    let from = point("from"), to = point("to")
                    if let from, let to {
                        if from == to {
                            problem(path + ".to", "Arrow to must differ from from (nonzero length).", index: index)
                        } else { annotation = .arrow(from: from, to: to, color: color) }
                    }
                case "rect":
                    let x = coordinate(fields["x"], field: "x", bound: image.width)
                    let y = coordinate(fields["y"], field: "y", bound: image.height)
                    func dimension(_ key: String, origin: Double?, bound: Int) -> Double? {
                        guard let n = number(fields[key]), n > 0, n <= Double(bound),
                              origin.map({ n <= Double(bound) - $0 }) ?? true else {
                            problem(path + "." + key, "Expected a finite positive image-pixel size; origin + \(key) must be <= \(bound).", index: index)
                            return nil
                        }
                        return n
                    }
                    let width = dimension("width", origin: x, bound: image.width)
                    let height = dimension("height", origin: y, bound: image.height)
                    if let x, let y, let width, let height {
                        annotation = .rect(CGRect(x: x / scale, y: y / scale,
                            width: width / scale, height: height / scale), color: color)
                    }
                default:
                    let x = coordinate(fields["x"], field: "x", bound: image.width)
                    let y = coordinate(fields["y"], field: "y", bound: image.height)
                    let text = fields["text"] as? String
                    if let text { totalBytes += text.utf8.count }
                    if text == nil || text!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text!.utf8.count > maxTextBytes {
                        problem(path + ".text", "Expected nonblank text, at most 16384 UTF-8 bytes; explicit newlines are supported.", index: index)
                    }
                    if problems.count == before, totalBytes <= maxTotalTextBytes, items.count <= maxAnnotations {
                        annotation = .text(text!, at: AnnotationRenderer.textAnchor(topLeft:
                            CGPoint(x: x! / scale, y: y! / scale), text: text!, style: resolved), color: color)
                    }
                }
                if problems.count == before, items.count <= maxAnnotations, totalBytes <= maxTotalTextBytes,
                   let annotation {
                    annotations.append(annotation)
                }
            }
            if totalBytes > maxTotalTextBytes { problem("annotations", "Combined text must be at most 262144 UTF-8 bytes.") }
        } else { problem("annotations", "Required ordered array of 1...\(maxAnnotations) annotation objects.") }
        guard problems.isEmpty else { throw AgentFailure(.invalidAnnotations, "Invalid annotation batch.", problems: problems) }
        return EditDocument(image: image, scale: scale, annotations: annotations,
                            annotationStyle: style.annotationID, resolvedStyle: resolved)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
}
