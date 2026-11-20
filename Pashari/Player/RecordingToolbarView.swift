import SwiftUI

/// What the player's toolbar shows. The window controller keeps it up to
/// date.
@Observable
final class RecordingPlayerModel {
    var canTrim = false
    var canUndo = false
    var canRedo = false
    /// While the trim handles are out, or the recording is being cut,
    /// copied or saved.
    var isBusy = false
}

/// The player's toolbar, like the editor's: Trim, Undo and Redo, then Copy
/// and Save.
struct RecordingToolbarView: View {
    @Bindable var model: RecordingPlayerModel
    let onTrim: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            tray {
                iconButton("scissors", label: String(localized: "Trim"), action: onTrim)
                    .keyboardShortcut("t")
                    .disabled(!model.canTrim)
            }
            tray {
                iconButton("arrow.uturn.backward", label: String(localized: "Undo"), action: onUndo)
                    .disabled(!model.canUndo)
                iconButton("arrow.uturn.forward", label: String(localized: "Redo"), action: onRedo)
                    .disabled(!model.canRedo)
            }

            Spacer(minLength: 12)

            Button(String(localized: "Copy"), action: onCopy)
                .buttonStyle(PillButtonStyle(isProminent: false))
                .fixedSize()
            Button(String(localized: "Save"), action: onSave)
                .buttonStyle(PillButtonStyle(isProminent: true))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: EditorToolbarView.height)
        .disabled(model.isBusy)
    }

    /// Buttons that belong together, on a rounded tray.
    private func tray<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func iconButton(_ symbolName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(ToolButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}
