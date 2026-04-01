import SwiftUI

extension CaptureView {

    // MARK: - Displayed Turn

    @ViewBuilder
    var displayedTurnSection: some View {
        if let turn = viewModel.displayedTurn {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.isProcessing && turn.output == nil {
                        AnimatedDotsView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(turn.output ?? turn.input)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Self.textPadding)
            }
        }
    }

    // MARK: - Capture Blockquote (delegate to shared view)

    func captureBlockquote(_ capture: CapturedContext) -> some View {
        CaptureBlockquoteView(capture: capture)
    }
}
