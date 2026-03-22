import SwiftUI

extension CaptureView {
    // MARK: - Constants

    private static let turnDividerVPadding: CGFloat = 4
    private static let bottomAnchorID = "bottom"

    // MARK: - Conversation History

    var conversationHistorySection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.conversationTurns.enumerated()), id: \.element.id) { index, turn in
                        let isProcessingTurn = viewModel.isProcessing && index == viewModel.conversationTurns.count - 1
                        ConversationTurnView(
                            turn: turn,
                            showLabels: viewModel.showConversationLabels,
                            modeName: viewModel.processedByModeName,
                            isProcessing: isProcessingTurn,
                            showCopyButton: true
                        )

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

    // MARK: - Capture Blockquote (delegate to shared view)

    func captureBlockquote(_ capture: CapturedContext) -> some View {
        CaptureBlockquoteView(capture: capture)
    }
}
