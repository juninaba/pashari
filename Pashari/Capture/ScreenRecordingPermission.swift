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
        let defaults = UserDefaults.standard
        var hasAsked = defaults.bool(forKey: hasAskedKey)
        let granted = ensureGranted(
            isGranted: CGPreflightScreenCaptureAccess,
            request: CGRequestScreenCaptureAccess,
            showInstructions: { showInstructions() },
            hasAsked: &hasAsked
        )
        defaults.set(hasAsked, forKey: hasAskedKey)
        return granted
    }

    /// The steps of `ensureGranted()`, with the calls to macOS passed in so
    /// that tests can stand in for them. `hasAsked` tells whether an earlier
    /// attempt has asked already, and becomes true once one has. (`inout`
    /// lets the function change the caller's variable.)
    static func ensureGranted(
        isGranted: () -> Bool,
        request: () -> Bool,
        showInstructions: () -> Void,
        hasAsked: inout Bool
    ) -> Bool {
        if isGranted() {
            return true
        }

        // Ask on every attempt, not only the first. macOS shows its prompt,
        // and adds Pashari to the list in System Settings, only while
        // Pashari is missing from that list; otherwise the request returns
        // at once. The entry can go missing later, for example through
        // `tccutil reset` or the minus button under the list. Asking only
        // once would then leave nothing there for the user to turn on.
        if request() {
            return true
        }

        // macOS does not say whether it showed its prompt. On the first
        // attempt it normally does, so that one is left to it, and later
        // attempts get our explanation. (Right after the entry went missing,
        // both appear together; they lead to the same switch.)
        if !hasAsked {
            hasAsked = true
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

        if ModalPresentation.run({ alert.runModal() }) == .alertFirstButtonReturn {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: pane) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
