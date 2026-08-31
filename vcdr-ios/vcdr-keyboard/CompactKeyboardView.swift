import SwiftUI

/// The Compact Keyboard: VCDR's dictation controls without the key rows — a
/// control row carrying the same content as the Full Keyboard's toolbar strip,
/// with the chevron at its right end pointing up instead of down.
///
/// Rendered by `KeyboardView`'s `collapsedView` builder whenever KeyboardKit's
/// `isKeyboardCollapsed` is set. `KeyboardDisplayModeManager` owns the flag and
/// the persisted mode; it sizes the extension from `intrinsicHeight` below, so
/// this view's constants are the single source of the Compact height.
struct CompactKeyboardView: View {

    // MARK: - Constants

    private static let pillHeight: CGFloat = 32
    private static let horizontalPadding: CGFloat = 10
    private static let topPadding: CGFloat = 8

    /// Clearance under the control row. Wider than `topPadding` because on
    /// home-indicator devices this is where the indicator lands.
    private static let bottomPadding: CGFloat = 20

    /// What the extension's frame has to be for this layout to fit exactly.
    /// Read by `KeyboardDisplayModeManager` to pin the Compact height — every
    /// point above this is dead space between the controls and the host app.
    ///
    /// The status text costs nothing here: it shares the control row's line
    /// with the pills rather than claiming one of its own, so the frame is the
    /// same whether or not a run is in progress. See vcdr-ios ADR-0004.
    static var intrinsicHeight: CGFloat {
        topPadding + pillHeight + bottomPadding
    }

    @ObservedObject var controller: KeyboardViewController
    @ObservedObject var reachability: KeyboardReachabilityMonitor

    /// Drives the Discard Warning wash. Compact paints no background of its own
    /// so the host app shows through; the wash is the one exception, and only
    /// for as long as a hold lasts — at rest its progress is 0 and the row is
    /// fully transparent again.
    @State private var wash = DiscardWarningWashState()

    /// Where the current hold is, for the status row's narration. Separate from
    /// `wash` because the words must go the instant the hold ends, while the
    /// colour is still easing out.
    @State private var narration = HoldNarrationState()

    var body: some View {
        HStack {
            KeyboardStripLeading(controller: controller, narration: narration)
            Spacer()
            DictateActionButton(
                dictationState: controller.dictationState,
                recordsInPlace: reachability.recordsInPlace,
                showCapture: true,
                captureCount: controller.captureCount,
                onStart: { controller.startRecordingFromKeyboard() },
                onStop: { controller.stopAndWaitForResult() },
                onDiscard: {
                    wash.beginDiscardUnwind()
                    narration.end()
                    controller.discardRecordingFromKeyboard()
                },
                onInsert: { controller.insertPendingText() },
                onCapture: { controller.captureSelectedText() },
                onShowFailure: { controller.showFailureReason() },
                onWarningRamp: {
                    wash.ramp(to: $0)
                    narration.ramp(to: $0)
                },
                onWarningEnd: {
                    wash.end()
                    narration.end()
                }
            )
            KeyboardModeToggleButton(direction: .expand) {
                controller.expandKeyboard()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, Self.topPadding)
        .discardWarningWash(progress: wash.progress)
        // Belt-and-braces: whatever ends the run, the wash cannot outlive it,
        // so Compact returns fully transparent even off an unexpected path.
        .onChange(of: controller.dictationState) { _, newState in
            if newState != .recording {
                wash.end()
                narration.end()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
