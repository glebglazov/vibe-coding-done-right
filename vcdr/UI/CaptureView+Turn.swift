import SwiftUI

extension CaptureView {

    // MARK: - Displayed Turn

    @ViewBuilder
    var displayedTurnSection: some View {
        if let turn = viewModel.displayedTurn {
            let isProcessingTurn = viewModel.isProcessing
            VStack(alignment: .leading, spacing: 0) {
                DisplayedTurnView(
                    turn: turn,
                    showLabels: viewModel.showLabels,
                    modeName: viewModel.processedByModeName,
                    isProcessing: isProcessingTurn,
                    showCopyButton: true
                )
            }
            .padding(Self.textPadding)
        }
    }

    // MARK: - Capture Blockquote (delegate to shared view)

    func captureBlockquote(_ capture: CapturedContext) -> some View {
        CaptureBlockquoteView(capture: capture)
    }
}
