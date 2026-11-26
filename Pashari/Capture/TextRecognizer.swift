import Foundation
import Vision

enum TextRecognizer {
    @concurrent
    static func recognize(_ image: CGImage) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        // The Japanese model also recognizes Latin characters in mixed-script lines.
        request.recognitionLanguages = ["ja-JP", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])

        typealias Fragment = (text: String, bounds: CGRect)
        let fragments = (request.results ?? [])
            .compactMap { observation -> Fragment? in
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { return nil }
                return (text, observation.boundingBox)
            }
            .sorted { $0.bounds.midY > $1.bounds.midY } // Vision's origin is at the bottom left.

        var rows: [[Fragment]] = []
        for fragment in fragments {
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
