import Foundation
import Vision
import CoreGraphics

enum HistorySearch {
    /// All query terms must appear contiguously, but can match different fields.
    /// Exact fields and word starts rank higher; recency breaks ties.
    static func matches(_ query: String, in entries: [HistoryEntry]) -> [HistoryEntry] {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.compactMap { entry -> (HistoryEntry, Int)? in
            let fields = entry.searchFields.map(normalized)
            var total = 0
            for term in terms {
                guard let best = fields.compactMap({ score(term, in: $0) }).max() else { return nil }
                total += best
            }
            return (entry, total)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.modifiedAt != $1.0.modifiedAt { return $0.0.modifiedAt > $1.0.modifiedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map(\.0)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func score(_ term: String, in field: String) -> Int? {
        if field == term { return 1200 }
        if let range = field.range(of: term) {
            let boundary = range.lowerBound == field.startIndex || !field[field.index(before: range.lowerBound)].isLetter
            return boundary ? 1100 : 1000
        }
        return nil
    }

    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
