import SwiftUI

/// The leading end of the control strip, on both keyboard states: the settings
/// pills, replaced by the Discard Hint for as long as the Stop pill is held.
/// Used by Full and Compact alike so they can't diverge.
///
/// One slot rather than two stacked lines. The strip is at most ~400pt wide and
/// the action button and chevron take a third of it, so the hint's widest
/// string ("Hold STOP to discard") does not fit *beside* the pills — only
/// *instead of* them. The alternative, a line of the hint's own, cost 20pt of
/// permanently reserved height that stood empty at idle: a quarter of the
/// Compact Keyboard.
///
/// The pills yield only while a hold is in progress, so AI mode and text style
/// stay reachable through a whole run — including transcription, which is
/// exactly when a wrong mode is worth correcting. The swap happens inside a
/// strip of fixed height, so the extension's frame still cannot move when a
/// run starts, ends, or is held. See vcdr-ios ADR-0004.
struct KeyboardStripLeading: View {
    private static let fontSize: CGFloat = 11

    @ObservedObject var controller: KeyboardViewController
    /// Where the hold is: hinting from a quarter-second in, then ramping.
    var narration: HoldNarrationState

    var body: some View {
        if narration.isHinting {
            StatusRow(
                content: StatusRowContent.resolve(
                    warningProgress: narration.warningProgress,
                    status: nil,
                    holdAvailable: true
                ),
                fontSize: Self.fontSize,
                color: Color(.secondaryLabel),
                isHoldNarration: true
            )
        } else {
            DictateSettingsPills(controller: controller)
        }
    }
}
