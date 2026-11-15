import SwiftUI

/// One history entry. A Discarded Conversation has a DISCARDED tag, the
/// Recorded Output Choice, grey text and a grey line at its leading edge.
struct HistoryRow: View {
    // MARK: - Constants

    private static let labelFontSize: CGFloat = 10
    private static let labelTracking: CGFloat = 2
    private static let tagHorizontalPadding: CGFloat = 5
    private static let tagVerticalPadding: CGFloat = 2
    private static let tagBorder: CGFloat = 1
    private static let discardedLineWidth: CGFloat = 3
    private static let discardedLineSpacing: CGFloat = 10
    private static let spinnerScale: CGFloat = 0.6

    let conversation: Conversation
    let theme: Theme
    let isCopied: Bool
    /// Set while "Process with AI" is at work on this entry.
    let choiceInProgress: ReprocessChoice?
    let failure: String?

    private var recordedChoice: RecordedOutputChoice? {
        guard case .discarded(let choice) = conversation.status else { return nil }
        return choice
    }

    var body: some View {
        HStack(spacing: Self.discardedLineSpacing) {
            if recordedChoice != nil {
                Rectangle()
                    .fill(theme.onSurfaceVariant)
                    .frame(width: Self.discardedLineWidth)
            }
            content
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.15), value: isCopied)
        .contextMenu {
            Button("Copy") {
                UIPasteboard.general.string = conversation.copyableText
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                header
                Spacer(minLength: 0)
                if isCopied {
                    label("COPIED", color: theme.primary)
                        .transition(.opacity)
                }
            }
            Text(conversation.previewText)
                .font(.system(size: 14))
                .foregroundStyle(recordedChoice == nil ? theme.onSurface : theme.onSurfaceVariant)
                .lineLimit(4)
            if conversation.hadExternalProcessing {
                Text(conversation.inputText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(3)
            }
            if let failure, choiceInProgress == nil {
                Text(failure)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primary)
            }
            Text(conversation.capturedAt.formatted(
                .dateTime.month(.abbreviated).day().hour().minute()
            ))
            .font(.system(size: 11, weight: .medium))
            .tracking(1)
            .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let choiceInProgress {
            ProgressView()
                .tint(theme.onSurfaceVariant)
                .scaleEffect(Self.spinnerScale)
            label("PROCESSING WITH AI · \(choiceInProgress.label)", color: theme.onSurfaceVariant)
        } else if let recordedChoice {
            label("DISCARDED", color: theme.onSurfaceVariant)
                .padding(.horizontal, Self.tagHorizontalPadding)
                .padding(.vertical, Self.tagVerticalPadding)
                .overlay(Rectangle().stroke(theme.onSurfaceVariant, lineWidth: Self.tagBorder))
            label(recordedChoice.displayLabel, color: theme.onSurfaceVariant)
        } else if let text = conversation.label, conversation.hadExternalProcessing {
            label(text, color: theme.onSurfaceVariant)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: Self.labelFontSize, weight: .bold))
            .tracking(Self.labelTracking)
            .foregroundStyle(color)
    }
}
