import SwiftUI

struct EditorToolbarView: View {
    static let height: CGFloat = 50

    @Bindable var model: EditorModel
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            group {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            group {
                ForEach(AnnotationColor.allCases) { color in
                    colorButton(color)
                }
                Divider().frame(height: 18).padding(.horizontal, 4)
                ForEach(StrokeSize.allCases) { size in
                    sizeButton(size)
                }
            }

            Spacer(minLength: 12)

            group {
                iconButton("arrow.uturn.backward", label: String(localized: "Undo"), action: onUndo)
                    .disabled(!model.canUndo)
                iconButton("arrow.uturn.forward", label: String(localized: "Redo"), action: onRedo)
                    .disabled(!model.canRedo)
            }
            iconButton("pin", label: String(localized: "Pin to Screen"), action: onPin)
            // `fixedSize` keeps these two at their natural width, so their
            // titles are never shortened to "Co…" in a narrow window.
            Button(String(localized: "Copy"), action: onCopy)
                .buttonStyle(PillButtonStyle(isProminent: false))
                .fixedSize()
            Button(String(localized: "Save"), action: onSave)
                .buttonStyle(PillButtonStyle(isProminent: true))
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .disabled(model.isExporting)
    }

    /// Buttons that belong together, on a rounded tray.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Buttons

    private func toolButton(_ tool: EditorTool) -> some View {
        iconButton(tool.symbolName, label: tool.label, isSelected: model.tool == tool) {
            model.tool = tool
        }
    }

    private func colorButton(_ color: AnnotationColor) -> some View {
        let isSelected = model.color == color
        return Button {
            model.color = color
        } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.label)
        .accessibilityLabel(color.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sizeButton(_ size: StrokeSize) -> some View {
        let isSelected = model.size == size
        return Button {
            model.size = size
        } label: {
            Circle()
                .fill(.primary)
                .frame(width: size.lineWidth + 3, height: size.lineWidth + 3)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(isSelected ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(size.label)
        .accessibilityLabel(size.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func iconButton(
        _ symbolName: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(Circle().fill(isSelected ? EditorStyle.accent : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(ToolButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lights up under the pointer, and dims while pressed or unavailable. The
/// recording player's toolbar uses it too.
struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration)
    }
}

/// A view of its own, because only a view can keep state such as whether
/// the pointer is over it.
private struct ToolButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .onHover { isHovered = $0 }
    }
}

/// Copy and Save: rounded, the more important one filled with the accent.
/// Settings uses it too.
struct PillButtonStyle: ButtonStyle {
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(
                Capsule().fill(isProminent ? AnyShapeStyle(EditorStyle.accent) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

extension AnnotationColor {
    var label: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .black: String(localized: "Black")
        case .white: String(localized: "White")
        }
    }
}

extension StrokeSize {
    var label: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }
}
