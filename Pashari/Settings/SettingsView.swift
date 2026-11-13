import AppKit
import KeyboardShortcuts
import SwiftUI

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

                LabeledContent("Save screenshots to") {
                    HStack(spacing: 8) {
                        Text(FileManager.default.displayName(atPath: model.saveDirectory.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.saveDirectory.path)
                        Button("Choose…") {
                            chooseSaveDirectory()
                        }
                    }
                }
            }

            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Capture Area", name: .captureArea)
                KeyboardShortcuts.Recorder("Capture Window", name: .captureWindow)
                KeyboardShortcuts.Recorder("Capture Fullscreen", name: .captureFullscreen)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.saveDirectory
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder Pashari saves screenshots to.")

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
