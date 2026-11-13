import AppKit
import KeyboardShortcuts
import SwiftUI

/// The contents of the Settings window.
///
/// SwiftUI is declarative: `body` describes what the window looks like for
/// the current state, and SwiftUI redraws it whenever a value it reads from
/// `model` changes.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                if let launchAtLoginError = model.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                // A label on the left, and on the right the current folder
                // with a button to pick another.
                LabeledContent("Save screenshots to") {
                    HStack(spacing: 8) {
                        Text(FileManager.default.displayName(atPath: model.saveDirectory.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            // The full path, as a tooltip.
                            .help(model.saveDirectory.path)
                        Button("Choose…") {
                            chooseSaveDirectory()
                        }
                    }
                }
            }

            Section("Shortcuts") {
                // Each recorder shows the current shortcut and lets the user
                // type a new one. The package saves the change by itself.
                KeyboardShortcuts.Recorder("Capture Area", name: .captureArea)
                KeyboardShortcuts.Recorder("Capture Window", name: .captureWindow)
                KeyboardShortcuts.Recorder("Capture Fullscreen", name: .captureFullscreen)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Shows the system's folder picker and remembers the choice.
    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.saveDirectory
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder Pashari saves screenshots to.")

        // `runModal` waits here until the user picks a folder or cancels.
        if ModalPresentation.run({ panel.runModal() }) == .OK, let url = panel.url {
            Preferences.setSaveDirectory(url)
            model.saveDirectory = url
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Nothing to do when the toggle already matches the system, which is
        // also the case right after it is put back following a failure.
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            model.launchAtLoginError = nil
        } catch {
            model.launchAtLoginError = error.localizedDescription
            model.launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
