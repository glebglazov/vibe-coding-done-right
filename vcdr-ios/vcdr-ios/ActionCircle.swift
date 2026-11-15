import SwiftUI

/// The recording screen's large round control: RECORD at rest, STOP during a
/// run. One view, so the two cannot drift apart in size or style.
struct ActionCircle<Icon: View>: View {
    private typealias Metrics = ActionCircleMetrics

    @Environment(\.theme) private var theme

    let label: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(spacing: Metrics.labelSpacing) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(theme.primaryDim)
                        .frame(width: Metrics.size, height: Metrics.size)
                        .shadow(color: theme.primaryDim.opacity(Metrics.glowOpacity), radius: Metrics.glowRadius)
                    Circle()
                        .stroke(theme.surfaceHighest, lineWidth: Metrics.border)
                        .frame(width: Metrics.size, height: Metrics.size)
                    icon()
                }
            }
            .accessibilityLabel(label)
            Text(label)
                .font(.system(size: Metrics.labelFontSize, weight: .bold))
                .tracking(Metrics.labelTracking)
                .foregroundStyle(theme.onSurface)
                .accessibilityHidden(true)
        }
    }
}

/// Kept outside the generic view, which cannot hold stored static constants.
enum ActionCircleMetrics {
    static let size: CGFloat = 96
    static let border: CGFloat = 8
    static let glowRadius: CGFloat = 20
    static let glowOpacity: Double = 0.2
    static let labelSpacing: CGFloat = 16
    static let labelFontSize: CGFloat = 10
    static let labelTracking: CGFloat = 3
}
