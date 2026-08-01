import SwiftUI

/// The reserved row above the dictation controls, on both keyboard states.
///
/// Carries the Discard Hint while a run is recording and stands empty
/// otherwise — but it is reserved at `height` either way, so the extension
/// never changes height when a run starts, stops, or while a hold is in
/// progress. `height` is the one constant both states size themselves from:
/// `CompactKeyboardView.intrinsicHeight` folds it into the pinned Compact
/// frame, `KeyboardDisplayModeManager.fullToolbarHeight` into the Full strip.
struct DiscardHintRow: View {

    /// Sized to the hint text at `font`. Tune here and both states follow.
    static let height: CGFloat = 20

    private static let font: CGFloat = 11

    var isRecording: Bool

    var body: some View {
        Group {
            if isRecording {
                Text("Hold STOP to discard")
                    .font(.system(size: Self.font, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color(.secondaryLabel))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }
}
