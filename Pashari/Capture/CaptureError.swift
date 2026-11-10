import Foundation

/// Things that can go wrong between the menu click and the saved file.
///
/// Conforming to `LocalizedError` lets `error.localizedDescription` return the
/// text from `errorDescription`, so the alert shows a readable message.
enum CaptureError: LocalizedError {
    case displayNotFound
    case cannotWriteFile(URL)

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            String(localized: "The display to capture could not be found.")
        case .cannotWriteFile(let url):
            String(localized: "The screenshot could not be saved to \(url.path).")
        }
    }
}
