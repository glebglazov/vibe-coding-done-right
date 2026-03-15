import SwiftUI

extension CaptureView {
    // MARK: - Constants

    private static let turnDividerVPadding: CGFloat = 4
    private static let labelVPadding: CGFloat = 4
    private static let copyButtonSize: CGFloat = 12
    private static let blockquoteBorderWidth: CGFloat = 2
    private static let blockquoteBorderSpacing: CGFloat = 6
    private static let blockquoteBorderOpacity: Double = 0.4
    private static let blockquoteLeadingPadding: CGFloat = 4
    private static let bottomAnchorID = "bottom"

    // MARK: - Conversation History

    var conversationHistorySection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.conversationTurns.enumerated()), id: \.element.id) { index, turn in
                        let isProcessingTurn = viewModel.isProcessing && index == viewModel.conversationTurns.count - 1
                        turnView(turn, showLabels: viewModel.showConversationLabels, isProcessingTurn: isProcessingTurn)

                        if index < viewModel.conversationTurns.count - 1 {
                            Divider()
                                .padding(.vertical, Self.turnDividerVPadding)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(Self.textPadding)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: viewModel.scrollTrigger) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ turn: ConversationTurn, showLabels: Bool, isProcessingTurn: Bool = false) -> some View {
        if showLabels {
            Text("You:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, Self.labelVPadding)

            turnInputView(turn)
                .padding(.bottom, Self.labelVPadding)

            HStack {
                if !isProcessingTurn {
                    copyButton(for: turn.output)
                }
                Text("Result:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let modeName = viewModel.processedByModeName {
                    Text(modeName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }
            .padding(.bottom, Self.labelVPadding)
        }

        if isProcessingTurn && (turn.output.isEmpty || turn.output == "...") {
            AnimatedDotsView()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(turn.output)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Turn Input

    /// Renders the turn's input text interleaved with capture blockquotes.
    /// Parses `<capture-N>...</capture-N>` tags from `resolveSubmissionText()` and
    /// displays the text parts as monospaced body and captures as blockquotes.
    @ViewBuilder
    private func turnInputView(_ turn: ConversationTurn) -> some View {
        let parts = parseTurnInput(turn.input, captures: turn.captures)
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .text(let value):
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .capture(let context):
                captureBlockquote(context)
            }
        }
    }

    private enum TurnInputPart {
        case text(String)
        case capture(CapturedContext)
    }

    /// Splits input text on `<capture-N>...</capture-N>` boundaries, pairing each
    /// tag with the corresponding `CapturedContext` from the turn.
    private func parseTurnInput(_ input: String, captures: [CapturedContext]) -> [TurnInputPart] {
        guard !captures.isEmpty else {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }

        var parts: [TurnInputPart] = []
        var remaining = input
        var captureIndex = 0

        while captureIndex < captures.count {
            let tag = "<capture-\(captureIndex + 1)>"
            let endTag = "</capture-\(captureIndex + 1)>"

            if let tagRange = remaining.range(of: tag) {
                let before = String(remaining[remaining.startIndex..<tagRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    parts.append(.text(before))
                }
                parts.append(.capture(captures[captureIndex]))

                if let endRange = remaining.range(of: endTag) {
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    remaining = ""
                }
            } else {
                // Tag not found — append capture from the model directly
                parts.append(.capture(captures[captureIndex]))
            }
            captureIndex += 1
        }

        let trailing = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty {
            parts.append(.text(trailing))
        }

        return parts
    }

    // MARK: - Capture Blockquote

    func captureBlockquote(_ capture: CapturedContext) -> some View {
        HStack(alignment: .top, spacing: Self.blockquoteBorderSpacing) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(Self.blockquoteBorderOpacity))
                .frame(width: Self.blockquoteBorderWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(capture.text)
                    .font(.system(.callout))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, Self.blockquoteLeadingPadding)
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
