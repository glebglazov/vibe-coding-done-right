import SwiftUI

/// Shared view for rendering a single displayed turn with proper formatting.
/// Used by both CaptureView (live capture) and HistoryTabView (history display).
struct DisplayedTurnView: View {
    let turn: DisplayedTurn
    let showLabels: Bool
    var modeName: String?
    var isProcessing: Bool = false
    var showCopyButton: Bool = false

    // MARK: - Constants
    private static let labelVPadding: CGFloat = 4
    private static let copyButtonSize: CGFloat = 12

    var body: some View {
        if showLabels {
            Text("You:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, Self.labelVPadding)

            turnInputView
                .padding(.bottom, Self.labelVPadding)

            // "Result:" section — only when output exists or processing is in progress
            if turn.output != nil || isProcessing {
                HStack {
                    Text("Result:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let modeName {
                        Text(modeName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if showCopyButton, let output = turn.output, !isProcessing {
                        copyButton(for: output)
                    }
                }
                .padding(.bottom, Self.labelVPadding)

                outputView
            }
        } else {
            // No labels — single unprocessed turn. Just show the input.
            HStack(alignment: .top) {
                Text(turn.input)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showCopyButton {
                    copyButton(for: turn.input)
                }
            }
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var outputView: some View {
        if isProcessing && (turn.output == nil || turn.output?.isEmpty == true) {
            AnimatedDotsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let output = turn.output {
            Text(output)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Turn Input

    @ViewBuilder
    private var turnInputView: some View {
        let parts = turn.parseInput()
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .text(let value):
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .capture(let context):
                CaptureBlockquoteView(capture: context)
            }
        }
    }

    // MARK: - Helpers

    private func copyButton(for text: String) -> some View {
        Button {
            ClipboardHelper.writeString(text)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: Self.copyButtonSize))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Standalone capture blockquote view for rendering captured context as a styled quote.
struct CaptureBlockquoteView: View {
    let capture: CapturedContext

    // MARK: - Constants
    private static let borderWidth: CGFloat = 2
    private static let borderSpacing: CGFloat = 6
    private static let borderOpacity: Double = 0.4
    private static let leadingPadding: CGFloat = 4

    var body: some View {
        HStack(alignment: .top, spacing: Self.borderSpacing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(Self.borderOpacity))
                .frame(width: Self.borderWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(capture.text)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Self.leadingPadding)
    }
}
