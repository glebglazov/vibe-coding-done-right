import SwiftUI

/// The Compact Keyboard: VCDR's dictation controls without the key rows — a
/// single row carrying the same content as the Full Keyboard's toolbar strip,
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
    static var intrinsicHeight: CGFloat {
        topPadding + pillHeight + bottomPadding
    }

    @ObservedObject var controller: KeyboardViewController

    var body: some View {
        HStack {
            DictateSettingsPills(controller: controller)
            Spacer()
            DictateActionButton(
                dictationState: controller.dictationState,
                showCapture: true,
                captureCount: controller.captureCount,
                onStart: { controller.startRecordingFromKeyboard() },
                onStop: { controller.stopAndWaitForResult() },
                onDiscard: { controller.discardRecordingFromKeyboard() },
                onInsert: { controller.insertPendingText() },
                onCapture: { controller.captureSelectedText() }
            )
            KeyboardModeToggleButton(direction: .expand) {
                controller.expandKeyboard()
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, Self.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
