import SwiftUI

/// The controls at the bottom of a run: STOP in the centre, and a smaller
/// DISCARD to its left with the two circle centres on one line. DISCARD is a
/// separate control so that STOP is only ever a tap that stops and
/// transcribes (ADR-0010).
struct RunControlDock: View {
    // MARK: - Constants

    private static let stopIconSize: CGFloat = 32
    private static let discardSize: CGFloat = 56
    private static let discardBorder: CGFloat = 1.5
    private static let discardIconSize: CGFloat = 22
    /// Horizontal distance from STOP's centre to DISCARD's centre.
    private static let discardCenterOffset: CGFloat = 116

    @Environment(\.theme) private var theme

    let onStop: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        ActionCircle(label: "STOP", action: onStop) {
            Rectangle()
                .fill(theme.onSurface)
                .frame(width: Self.stopIconSize, height: Self.stopIconSize)
        }
        // An overlay, so DISCARD never moves STOP off the screen's centre line.
        .overlay(alignment: .top) {
            discard
                .offset(
                    x: -Self.discardCenterOffset,
                    y: (ActionCircleMetrics.size - Self.discardSize) / 2
                )
        }
    }

    private var discard: some View {
        VStack(spacing: ActionCircleMetrics.labelSpacing) {
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: Self.discardIconSize, weight: .bold))
                    .foregroundStyle(theme.onSurface)
                    .frame(width: Self.discardSize, height: Self.discardSize)
                    .background(Circle().fill(theme.surfaceHigh))
                    .overlay(Circle().stroke(theme.onSurfaceVariant, lineWidth: Self.discardBorder))
                    .contentShape(Circle())
            }
            .accessibilityLabel("Discard recording")
            Text("DISCARD")
                .font(.system(size: ActionCircleMetrics.labelFontSize, weight: .bold))
                .tracking(ActionCircleMetrics.labelTracking)
                .foregroundStyle(theme.onSurfaceVariant)
                .accessibilityHidden(true)
        }
    }
}
