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
    /// The Discard control costs nothing here: it takes the settings pills'
    /// place on the control row during a run, so the frame is the same
    /// whether or not a run is in progress (ADR-0010).
    static var intrinsicHeight: CGFloat {
        topPadding + pillHeight + bottomPadding
    }

    @ObservedObject var model: KeyboardDictationModel
    weak var controller: KeyboardViewController?
    @ObservedObject var reachability: KeyboardReachabilityMonitor

    var body: some View {
        HStack {
            KeyboardStripLeading(model: model, controller: controller)
            Spacer()
            DictateActionButton(
                dictationState: model.dictationState,
                recordsInPlace: reachability.recordsInPlace,
                onStart: { controller?.startRecordingFromKeyboard() },
                onStop: { controller?.stopAndWaitForResult() },
                onInsert: { controller?.insertPendingText() },
                onShowFailure: { controller?.showFailureReason() }
            )
            KeyboardModeToggleButton(direction: .expand) {
                controller?.expandKeyboard()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, Self.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
