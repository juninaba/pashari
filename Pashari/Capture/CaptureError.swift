import Foundation

enum CaptureError: LocalizedError {
    case displayNotFound
    case cannotEncodeImage
    case cannotWriteFile(URL)
    case cannotReadFile(URL)
    case cannotApplyEdits

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            String(localized: "The display to capture could not be found.")
        case .cannotEncodeImage:
            String(localized: "The screenshot could not be converted to PNG.")
        case .cannotApplyEdits:
            String(localized: "The annotations and crop could not be applied to the screenshot.")
        case .cannotWriteFile(let url):
            String(localized: "The screenshot could not be saved to \(url.path).")
        case .cannotReadFile(let url):
            String(localized: "The screenshot could not be read from \(url.path).")
        }
    }
}
