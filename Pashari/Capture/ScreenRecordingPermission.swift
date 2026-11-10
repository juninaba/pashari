import AppKit

/// The macOS "Screen & System Audio Recording" permission.
///
/// Without it the system refuses to hand over screen contents. The user grants
/// it in System Settings; an app cannot grant it to itself.
enum ScreenRecordingPermission {
    private static let hasAskedKey = "hasAskedForScreenRecordingPermission"

    /// Returns true when capturing is allowed. Otherwise guides the user to
    /// System Settings and returns false.
    static func ensureGranted() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        // macOS shows its own prompt only the first time an app asks, and does
        // not say whether it did. So remember that we asked, and show our own
        // explanation on later attempts.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: hasAskedKey) {
            defaults.set(true, forKey: hasAskedKey)
            // Also adds Pashari to the list in System Settings.
            if CGRequestScreenCaptureAccess() {
                return true
            }
            return false
        }

        showInstructions()
        return false
    }

    private static func showInstructions() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pashari needs permission to record the screen")
        alert.informativeText = String(
            localized: """
            Turn on Pashari under Privacy & Security > Screen & System Audio Recording \
            in System Settings, then quit and reopen Pashari.
            """
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        // A menu bar app is never the active app on its own, so bring the
        // alert to the front explicitly.
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
