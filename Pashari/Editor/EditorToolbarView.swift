import SwiftUI

struct EditorToolbarView: View {
    static let height: CGFloat = 46

    @Bindable var model: EditorModel
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    toolButton(tool)
                }
            }
            separator
            HStack(spacing: 2) {
                ForEach(AnnotationColor.allCases) { color in
                    colorButton(color)
                }
            }
            separator
            HStack(spacing: 2) {
                ForEach(StrokeSize.allCases) { size in
                    sizeButton(size)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", label: String(localized: "Undo"), action: onUndo)
                    .disabled(!model.canUndo)
                iconButton("arrow.uturn.forward", label: String(localized: "Redo"), action: onRedo)
                    .disabled(!model.canRedo)
            }
            separator
            // `fixedSize` keeps these two at their natural width, so their
            // titles are never shortened to "Co…" in a narrow window.
            Button(String(localized: "Copy"), action: onCopy)
                .fixedSize()
            Button(String(localized: "Save"), action: onSave)
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .disabled(model.isExporting)
    }

    private var separator: some View {
        Divider().frame(height: 22)
    }

    // MARK: - Buttons

    private func toolButton(_ tool: EditorTool) -> some View {
        iconButton(tool.symbolName, label: tool.label, isSelected: model.tool == tool) {
            model.tool = tool
        }
    }

    private func colorButton(_ color: AnnotationColor) -> some View {
        Button {
            model.color = color
        } label: {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.label)
        .accessibilityLabel(color.label)
    }

    private func sizeButton(_ size: StrokeSize) -> some View {
        Button {
            model.size = size
        } label: {
            Circle()
                .fill(.primary)
                .frame(width: size.lineWidth + 3, height: size.lineWidth + 3)
                .frame(width: 26, height: 28)
                .background(selectionBackground(model.size == size))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(size.label)
        .accessibilityLabel(size.label)
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
                .frame(width: 30, height: 28)
                .background(selectionBackground(isSelected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func selectionBackground(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.28) : .clear)
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
