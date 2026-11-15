import SwiftUI

/// A Discarded Conversation in the History list: its verbatim words in grey,
/// a DISCARDED tag with the recorded Mode and Style, and the actions that
/// process it with AI.
struct DiscardedConversationRowView: View {
    let conversation: Conversation
    let choice: RecordedOutputChoice
    let modes: [Mode]
    let isProcessing: Bool
    let failure: String?
    /// Nil processes with the recorded Mode.
    let onProcess: (Mode?) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    // MARK: - Constants

    private static let tagHPadding: CGFloat = 5
    private static let tagVPadding: CGFloat = 1
    private static let rowSpacing: CGFloat = 4
    private static let tagBackgroundOpacity: Double = 0.2

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            header
            Text(conversation.inputText)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text(conversation.capturedAt.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
    }

    private var header: some View {
        HStack {
            Text("DISCARDED")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, Self.tagHPadding)
                .padding(.vertical, Self.tagVPadding)
                .background(Color.secondary.opacity(Self.tagBackgroundOpacity), in: Capsule())
            Text(choice.displayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isProcessing {
                ProgressView().controlSize(.small)
                Text("Processing with AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isHovering {
                Button("Process with AI", systemImage: "sparkles") { onProcess(nil) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                Button("Copy") { ClipboardHelper.writeString(conversation.copyableText) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Process with AI") { onProcess(nil) }
            .disabled(isProcessing)
        Menu("Process with AI as") {
            ForEach(modes) { mode in
                Button(mode.name) { onProcess(mode) }
            }
        }
        .disabled(isProcessing)
        Divider()
        Button("Copy") { ClipboardHelper.writeString(conversation.copyableText) }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}
