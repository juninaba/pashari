import AppKit

/// Whether Pashari's windows are light or dark: as in macOS, or as picked
/// in Settings. The thumbnails turn dark too; the paper of the prints in
/// the editor stays light either way.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// Every window takes the app's appearance unless it has its own, as
    /// the scroll capture bar does. Nil follows macOS, and keeps following
    /// it when it changes there.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
