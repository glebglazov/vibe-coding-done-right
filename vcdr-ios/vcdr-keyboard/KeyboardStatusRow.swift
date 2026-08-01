import SwiftUI

/// The keyboard's rendering of the shared reserved row — same content source
/// and same fixed height as the app's, in the keyboard's own type size and
/// colour. Used by both keyboard states so Full and Compact can't diverge.
struct KeyboardStatusRow: View {
    private static let fontSize: CGFloat = 11

    var dictationState: DictationState
    /// Non-nil only while a hold's Discard Warning is ramping.
    var warningProgress: CGFloat?

    var body: some View {
        StatusRow(
            content: StatusRowContent.resolve(
                warningProgress: warningProgress,
                status: dictationState.transientStatus,
                holdAvailable: dictationState == .recording
            ),
            fontSize: Self.fontSize,
            color: Color(.secondaryLabel),
            isHoldNarration: warningProgress != nil
        )
    }
}

extension DictationState {
    /// Which run states have something to say in the reserved row. `.recording`
    /// is absent because the hold tenants own it, and `.cancelled` because the
    /// CANCELLED pill already owns that moment.
    var transientStatus: TransientStatus? {
        switch self {
        case .transcribing: .transcribing
        case .emptyResult: .noSpeechDetected
        case .idle, .recording, .ready, .cancelled: nil
        }
    }
}
