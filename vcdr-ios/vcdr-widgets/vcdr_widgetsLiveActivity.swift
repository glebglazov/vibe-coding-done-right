import ActivityKit
import WidgetKit
import SwiftUI

struct HotMicLiveActivity: Widget {
    private static let readyTitle = "Ready to record"
    /// Shown once the card's stale horizon has passed. VCDR is no longer
    /// reachable in place, so the card must claim nothing: the next keyboard tap
    /// opens the app instead of recording where the user is typing (ADR-0006).
    private static let staleTitle = "VCDR is not running"
    private static let readyTag = "Ready"
    private static let staleTag = "Off"

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HotMicActivityAttributes.self) { context in
            HStack(spacing: 12) {
                iconBadge(size: 40, isStale: context.isStale)
                caption(isStale: context.isStale, titleFont: .body.weight(.medium))
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    iconBadge(size: 32, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.center) {
                    caption(isStale: context.isStale, titleFont: .callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) { EmptyView() }
            } compactLeading: {
                iconBadge(size: 20, isStale: context.isStale)
            } compactTrailing: {
                Text(context.isStale ? Self.staleTag : Self.readyTag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(context.isStale ? .secondary : .primary)
            } minimal: {
                iconBadge(size: 20, isStale: context.isStale)
            }
        }
    }

    @ViewBuilder
    private func caption(isStale: Bool, titleFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("VCDR")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(isStale ? Self.staleTitle : Self.readyTitle)
                .font(titleFont)
                .foregroundStyle(isStale ? .secondary : .primary)
        }
    }

    /// Drained of colour once stale, so the card reads as dormant at a glance —
    /// the wording is the claim, the tint is how far away it is.
    @ViewBuilder
    private func iconBadge(size: CGFloat, isStale: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.32, green: 0.68, blue: 0.70),
                         Color(red: 0.82, green: 0.42, blue: 0.52)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: isStale ? "waveform.slash" : "waveform")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .grayscale(isStale ? 1 : 0)
        .opacity(isStale ? 0.5 : 1)
    }
}
