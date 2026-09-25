#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Wire format between the app and the widget extension. `nonisolated` because
/// the widget process decodes it off the main actor, and under this project's
/// default main-actor isolation a plain struct's synthesized `Codable`
/// conformance would be isolated to an actor the decoder is not on.
nonisolated struct HotMicActivityAttributes: ActivityAttributes {
    typealias ContentState = MicPresenceCardState
}
#endif
