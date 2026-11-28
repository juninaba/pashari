import Foundation

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound
    case cannotEncodeImage
    case cannotWriteClipboard
    case cannotWriteFile(URL)
    case cannotReadFile(URL)
    case cannotApplyEdits
    case cannotSaveRecording(URL)
    case cannotReadRecording(URL)
    case cannotTrimRecording

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            String(localized: "The display to capture could not be found.")
        case .windowNotFound:
            String(localized: "The window to record could not be found.")
        case .cannotEncodeImage:
            String(localized: "The screenshot could not be converted to PNG.")
        case .cannotWriteClipboard:
            String(localized: "The clipboard could not be updated.")
        case .cannotApplyEdits:
            String(localized: "The annotations and crop could not be applied to the screenshot.")
        case .cannotWriteFile(let url):
            String(localized: "The screenshot could not be saved to \(url.path).")
        case .cannotReadFile(let url):
            String(localized: "The screenshot could not be read from \(url.path).")
        case .cannotSaveRecording(let url):
            String(localized: "The recording could not be saved to \(url.path).")
        case .cannotReadRecording(let url):
            String(localized: "The recording could not be read from \(url.path).")
        case .cannotTrimRecording:
            String(localized: "The recording could not be trimmed.")
        }
    }
}
