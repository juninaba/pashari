import Foundation
import Vision

enum TextRecognizer {
    typealias Fragment = (text: String, bounds: CGRect)

    @concurrent
    static func recognize(_ image: CGImage) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        // The Japanese model also recognizes Latin characters in mixed-script lines.
        request.recognitionLanguages = ["ja-JP", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let fragments = (request.results ?? []).compactMap { observation -> Fragment? in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
        return assemble(fragments)
    }

    nonisolated static func assemble(_ fragments: [Fragment]) -> String? {
        let ordered = fragments
            .compactMap { fragment -> Fragment? in
                let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (text, fragment.bounds)
            }
            .sorted { $0.bounds.midY > $1.bounds.midY } // Vision's origin is at the bottom left.

        var rows: [[Fragment]] = []
        for fragment in ordered {
            if let first = rows.last?.first, shareRow(first.bounds, fragment.bounds) {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        let text = rows.map { row in
            row.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private nonisolated static func shareRow(_ first: CGRect, _ second: CGRect) -> Bool {
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        return overlap > min(first.height, second.height) / 2
    }
}
