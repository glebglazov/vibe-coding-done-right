import SwiftUI

/// The actions of a Discarded Conversation: Process with AI, Copy raw text and
/// Delete. The choice starts as the Recorded Output Choice, and the menu at
/// the trailing end of Process with AI picks another mode or style.
struct DiscardedConversationSheet: View {
    // MARK: - Constants

    private static let headerFontSize: CGFloat = 10
    private static let headerTracking: CGFloat = 2
    private static let textFontSize: CGFloat = 14
    private static let textLineLimit = 6
    private static let actionFontSize: CGFloat = 16
    private static let choiceFontSize: CGFloat = 11
    private static let choiceTracking: CGFloat = 1.5
    private static let actionHeight: CGFloat = 52
    private static let actionBorder: CGFloat = 1.5
    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 12
    private static let sheetHeight: CGFloat = 380

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation
    let onProcess: (ReprocessChoice) -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var choice: ReprocessChoice

    init(
        conversation: Conversation,
        defaultChoice: ReprocessChoice,
        onProcess: @escaping (ReprocessChoice) -> Void,
        onCopy: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.onProcess = onProcess
        self.onCopy = onCopy
        self.onDelete = onDelete
        _choice = State(initialValue: defaultChoice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text("DISCARDED RECORDING · \(capturedAt)")
                .font(.system(size: Self.headerFontSize, weight: .bold))
                .tracking(Self.headerTracking)
                .foregroundStyle(theme.onSurfaceVariant)
            Text(conversation.inputText)
                .font(.system(size: Self.textFontSize))
                .foregroundStyle(theme.onSurfaceVariant)
                .lineLimit(Self.textLineLimit)

            processRow
            action("Copy raw text", icon: "doc.on.doc", color: theme.onSurface, perform: onCopy)
            action("Delete", icon: "trash", color: theme.primary, perform: onDelete)
            Spacer(minLength: 0)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surfaceContainer)
        .presentationDetents([.height(Self.sheetHeight)])
        .presentationDragIndicator(.visible)
    }

    private var capturedAt: String {
        conversation.capturedAt
            .formatted(.dateTime.month(.abbreviated).day().hour().minute())
            .uppercased()
    }

    private var processRow: some View {
        HStack(spacing: 0) {
            Button {
                onProcess(choice)
                dismiss()
            } label: {
                Label("Process with AI", systemImage: "sparkles")
                    .font(.system(size: Self.actionFontSize, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            choiceMenu
        }
        .foregroundStyle(theme.surfaceLowest)
        .padding(.horizontal, Self.padding)
        .frame(height: Self.actionHeight)
        .background(theme.primary)
    }

    private var choiceMenu: some View {
        Menu {
            Picker("Mode", selection: mode) {
                ForEach(ReprocessChoice.modes, id: \.self) { Text($0.displayName).tag($0) }
            }
            if choice.mode.appliesStyles {
                Picker("Style", selection: style) {
                    ForEach(TextStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(choice.label.uppercased())
                    .font(.system(size: Self.choiceFontSize, weight: .bold))
                    .tracking(Self.choiceTracking)
                Image(systemName: "chevron.right")
                    .font(.system(size: Self.choiceFontSize, weight: .bold))
            }
            .frame(height: Self.actionHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Mode and style: \(choice.label)")
    }

    private var mode: Binding<AIPromptMode> {
        Binding(
            get: { choice.mode },
            set: { choice = ReprocessChoice(mode: $0, style: choice.style) }
        )
    }

    private var style: Binding<TextStyle> {
        Binding(
            get: { choice.style },
            set: { choice = ReprocessChoice(mode: choice.mode, style: $0) }
        )
    }

    private func action(
        _ title: String,
        icon: String,
        color: Color,
        perform: @escaping () -> Void
    ) -> some View {
        Button {
            perform()
            dismiss()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: Self.actionFontSize, weight: .semibold))
                Spacer()
                Image(systemName: icon)
            }
            .foregroundStyle(color)
            .padding(.horizontal, Self.padding)
            .frame(height: Self.actionHeight)
            .overlay(Rectangle().stroke(color, lineWidth: Self.actionBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
