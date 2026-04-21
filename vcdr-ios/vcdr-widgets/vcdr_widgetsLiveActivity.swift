import ActivityKit
import WidgetKit
import SwiftUI

struct HotMicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HotMicActivityAttributes.self) { _ in
            HStack(spacing: 12) {
                iconBadge(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VCDR")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Ready to record")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    iconBadge(size: 32)
                }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VCDR")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Ready to record")
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) { EmptyView() }
            } compactLeading: {
                iconBadge(size: 20)
            } compactTrailing: {
                Text("Ready")
                    .font(.caption2.weight(.semibold))
            } minimal: {
                iconBadge(size: 20)
            }
        }
    }

    @ViewBuilder
    private func iconBadge(size: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.32, green: 0.68, blue: 0.70),
                         Color(red: 0.82, green: 0.42, blue: 0.52)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "waveform")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
