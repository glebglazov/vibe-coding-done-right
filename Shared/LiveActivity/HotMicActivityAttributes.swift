#if os(iOS) && canImport(ActivityKit)
import ActivityKit

struct HotMicActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}
}
#endif
