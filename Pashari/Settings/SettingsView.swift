import AppKit
import KeyboardShortcuts
import SwiftUI

/// Dressed like the editor: a header with the app's icon, then the
/// settings on its dotted desk, on cards of the same light paper as the
/// prints, which stays light in Dark Mode too.
struct SettingsView: View {
    /// Deep enough to read on the paper (5.1:1). The system red reaches only
    /// 3.3:1 there.
    private static let errorRed = Color(red: 196 / 255, green: 52 / 255, blue: 40 / 255)
    /// For the folder's name: quieter than the labels, yet as readable on the
    /// paper (5.7:1) as on the old dark form. The system grey reaches 3.9:1.
    private static let quietText = Color.black.opacity(0.6)

    @Bindable var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ViewThatFits(in: .vertical) {
                desk.fixedSize(horizontal: false, vertical: true)
                ScrollView { desk }
            }
        }
        .frame(width: 440)
    }

    private var desk: some View {
        settings
            .padding(20)
            .background(SettingsDesk())
    }

    /// The app's icon and the window's title, on the colour of the editor's
    /// toolbar. The title bar above shows the same colour.
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            Text("Pashari Settings")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: EditorToolbarView.height)
        .background(Color(nsColor: EditorStyle.header))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("General") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $model.launchAtLogin) {
                        // Wide, so that the switch sits at the end of the row.
                        Text("Launch at login")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(EditorStyle.accent)
                    .onChange(of: model.launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                    if let launchAtLoginError = model.launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.footnote)
                            .foregroundStyle(Self.errorRed)
                    }
                }
                .padding(.vertical, SettingsRowStyle.verticalPadding)

                Divider()

                // "Save to", as macOS's own screenshot tool has it: a longer label
                // left the folder's name no room.
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(FileManager.default.displayName(atPath: model.saveDirectory.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(Self.quietText)
                            // A form let the name be selected and copied.
                            .textSelection(.enabled)
                            .help(model.saveDirectory.path)
                        Button("Choose…") {
                            chooseSaveDirectory()
                        }
                        .buttonStyle(PillButtonStyle(isProminent: false))
                        .fixedSize()
                    }
                }

                Divider()

                LabeledContent("Shutter sound") {
                    Picker("Shutter sound", selection: $model.shutterSound) {
                        ForEach(ShutterSound.allCases) { sound in
                            Text(sound.label).tag(sound)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.shutterSound) { _, newValue in
                        Preferences.setShutterSound(newValue)
                        // So that the user hears what they picked.
                        newValue.play()
                    }
                }

                Divider()

                LabeledContent("Appearance") {
                    Picker("Appearance", selection: $model.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: model.appearance) { _, newValue in
                        Preferences.setAppearance(newValue)
                        newValue.apply()
                    }
                }
            }

            section("Recording") {
                Toggle(isOn: Binding(
                    get: { model.recordingAudio.systemAudio },
                    set: { setRecordSystemAudio($0) }
                )) {
                    Text("System audio")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(EditorStyle.accent)
                .padding(.vertical, SettingsRowStyle.verticalPadding)

                Divider()

                Toggle(isOn: Binding(
                    get: { model.recordingAudio.microphone },
                    set: { setRecordMicrophone($0) }
                )) {
                    Text("Microphone")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(EditorStyle.accent)
                .disabled(model.isRequestingMicrophonePermission)
                .padding(.vertical, SettingsRowStyle.verticalPadding)
            }

            section("Shortcuts") {
                shortcutRecorder("Capture Area", name: .captureArea)
                Divider()
                shortcutRecorder("Capture Window", name: .captureWindow)
                Divider()
                shortcutRecorder("Capture Fullscreen", name: .captureFullscreen)
                Divider()
                shortcutRecorder("Capture Scrolling Area", name: .captureScrollingArea)
                Divider()
                shortcutRecorder("Capture Text", name: .captureText)
                Divider()
                shortcutRecorder("Record Area", name: .recordArea)
                Divider()
                shortcutRecorder("Record Window", name: .recordWindow)
                Divider()
                shortcutRecorder("Record Fullscreen", name: .recordFullscreen)
            }
        }
        .labeledContentStyle(SettingsRowStyle())
    }

    private func shortcutRecorder(_ title: LocalizedStringKey, name: KeyboardShortcuts.Name) -> some View {
        KeyboardShortcuts.Recorder(title, name: name)
            .shortcutValidation { Hotkeys.validate($0, for: name) }
    }

    /// A heading on the desk, with its settings on a paper card below it.
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .background(SettingsCard())
            // The paper is light in Dark Mode too, so what is on it is
            // drawn as on a light window.
            .environment(\.colorScheme, .light)
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.saveDirectory
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder Pashari saves screenshots and recordings to.")

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

    private func setRecordSystemAudio(_ enabled: Bool) {
        model.recordingAudio.systemAudio = enabled
        Preferences.setRecordSystemAudio(enabled)
    }

    private func setRecordMicrophone(_ enabled: Bool) {
        guard !model.isRequestingMicrophonePermission else { return }
        if !enabled {
            model.recordingAudio.microphone = false
            Preferences.setRecordMicrophone(false)
            return
        }
        model.isRequestingMicrophonePermission = true
        Task {
            defer { model.isRequestingMicrophonePermission = false }
            guard await MicrophonePermission.requestForToggle() else { return }
            model.recordingAudio.microphone = true
            Preferences.setRecordMicrophone(true)
        }
    }
}

/// A row on a card: the label at the start and what it sets at the end, as
/// in a form. The system's own style still lays out the two.
private struct SettingsRowStyle: LabeledContentStyle {
    static let verticalPadding: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            configuration.label
        }
        .labeledContentStyle(.automatic)
        .padding(.vertical, Self.verticalPadding)
    }
}

/// A card of the prints' paper, with a soft shadow on the desk.
private struct SettingsCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ThumbnailStyle.cornerRadius, style: .continuous)
        shape
            .fill(Color(cgColor: ThumbnailStyle.paper))
            .overlay(shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

/// The editor's dotted desk.
private struct SettingsDesk: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorDeskView {
        EditorDeskView()
    }

    func updateNSView(_ nsView: EditorDeskView, context: Context) {}
}
