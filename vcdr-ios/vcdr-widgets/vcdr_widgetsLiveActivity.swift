import ActivityKit
import WidgetKit
import SwiftUI

struct HotMicLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HotMicActivityAttributes.self) { _ in
            HStack {
                Image("LiveActivityIcon")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Spacer()
            }
            .padding()
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image("LiveActivityIcon")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                DynamicIslandExpandedRegion(.trailing) { EmptyView() }
                DynamicIslandExpandedRegion(.center) { EmptyView() }
                DynamicIslandExpandedRegion(.bottom) { EmptyView() }
            } compactLeading: {
                Image("LiveActivityIcon")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image("LiveActivityIcon")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}
