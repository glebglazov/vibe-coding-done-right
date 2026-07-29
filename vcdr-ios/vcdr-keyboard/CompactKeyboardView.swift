import KeyboardKit
import SwiftUI

/// The Compact Keyboard: VCDR's dictation controls without the key rows,
/// claiming roughly half the Full Keyboard's height.
///
/// Rendered by `KeyboardView`'s `collapsedView` builder whenever KeyboardKit's
/// `isKeyboardCollapsed` is set. `KeyboardDisplayModeManager` owns the flag,
/// the persisted mode, and the extension's height — this view is layout only.
struct CompactKeyboardView: View {

    // MARK: - Constants

    private static let pillHeight: CGFloat = 32
    private static let pillBorder: CGFloat = 1.5
    private static let rowSpacing: CGFloat = 8
    private static let arrowIconSize: CGFloat = 12
    private static let globeIconSize: CGFloat = 16
    private static let globePillWidth: CGFloat = 44
    private static let horizontalPadding: CGFloat = 10
    private static let topPadding: CGFloat = 8

    @ObservedObject var controller: KeyboardViewController

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            expandPill

            HStack(spacing: Self.rowSpacing) {
                DictateSettingsPills(controller: controller)
                if controller.dictationState == .recording {
                    DictateCaptureButton(
                        captureCount: controller.captureCount,
                        onCapture: { controller.captureSelectedText() }
                    )
                }
                Spacer()
            }

            HStack {
                globeControl
                Spacer()
                DictateActionButton(
                    dictationState: controller.dictationState,
                    showCapture: false,
                    captureCount: controller.captureCount,
                    onStart: { controller.startRecordingFromKeyboard() },
                    onStop: { controller.stopAndWaitForResult() },
                    onDiscard: { controller.discardRecordingFromKeyboard() },
                    onInsert: { controller.insertPendingText() },
                    onCapture: { controller.captureSelectedText() }
                )
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, Self.topPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.keyboardBackground.ignoresSafeArea())
    }

    /// Wide pill with an up-arrow and no text — the escape hatch from Compact
    /// into the Full Keyboard.
    private var expandPill: some View {
        Button {
            KeyboardHaptics.light()
            controller.expandKeyboard()
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: Self.arrowIconSize, weight: .black))
                .foregroundStyle(Color(.label))
                .frame(maxWidth: .infinity)
                .frame(height: Self.pillHeight)
                .background(Capsule().fill(Color(.systemGray5)))
                .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))
                .contentShape(Capsule())
        }
    }

    /// Next-keyboard access, mandatory in every state for App Review: Compact
    /// has no bottom key row to carry the globe. `Keyboard.NextKeyboardButton`
    /// supplies the native behavior — tap switches, long-press lists keyboards.
    private var globeControl: some View {
        Keyboard.NextKeyboardButton {
            Image.keyboardGlobe
                .font(.system(size: Self.globeIconSize, weight: .medium))
                .foregroundStyle(Color(.label))
                .frame(width: Self.globePillWidth, height: Self.pillHeight)
                .background(Capsule().fill(Color(.systemGray5)))
                .overlay(Capsule().stroke(Color(.label), lineWidth: Self.pillBorder))
                .contentShape(Capsule())
        }
    }
}
