import SwiftUI

/// The leading end of the control strip, on both keyboard states: the settings
/// pills, or the Discard control while a run listens. Used by Full and Compact
/// alike so they can't diverge.
///
/// AI mode and text style are locked while a run listens (ADR-0010), so the
/// pills leave and the Discard control takes their place, at the end of the
/// strip away from STOP. The swap happens inside a strip of fixed height, so
/// the extension's frame cannot move when a run starts or ends.
struct KeyboardStripLeading: View {
    // MARK: - Constants

    private static let discardSize: CGFloat = 32
    private static let discardIconSize: CGFloat = 12
    private static let discardBorder: CGFloat = 1.5

    @ObservedObject var controller: KeyboardViewController

    var body: some View {
        if controller.areOutputChoicesLocked {
            discardButton
        } else {
            DictateSettingsPills(controller: controller)
        }
    }

    private var discardButton: some View {
        Button {
            KeyboardHaptics.medium()
            controller.discardRecordingFromKeyboard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: Self.discardIconSize, weight: .black))
                .foregroundStyle(Color(.label))
                .frame(width: Self.discardSize, height: Self.discardSize)
                .background(Circle().fill(Color(.systemGray5)))
                .overlay(Circle().stroke(Color(.label), lineWidth: Self.discardBorder))
                .contentShape(Circle())
        }
        .accessibilityLabel("Discard recording")
    }
}
