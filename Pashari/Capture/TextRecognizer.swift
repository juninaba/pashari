import Foundation
import Vision

enum TextRecognizer {
    @concurrent
    static func recognize(_ image: CGImage) async throws -> String? {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ja-JP"]
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        // Vision coordinates start at the bottom left.
        let text = (request.results ?? [])
            .sorted { first, second in
                let a = first.boundingBox
                let b = second.boundingBox
                return a.midY == b.midY ? a.minX < b.minX : a.midY > b.midY
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
