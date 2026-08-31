#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// Wire format between the app and the widget extension. `nonisolated` because
/// the widget process decodes it off the main actor, and under this project's
/// default main-actor isolation a plain struct's synthesized `Codable`
/// conformance would be isolated to an actor the decoder is not on.
nonisolated struct HotMicActivityAttributes: ActivityAttributes {
    /// Which of the two things VCDR is doing behind the system mic indicator.
    /// The third face — not ready — is not in here: it is driven by the stale
    /// horizon on the activity content, so iOS can still show it once this
    /// process is gone (ADR-0006).
    struct ContentState: Codable, Hashable {
        /// True while a Recording Run is capturing. A background recording is
        /// the case the card exists for: the orange dot alone cannot say whether
        /// VCDR is merely warm or is taking down what the user is saying.
        var isRecording: Bool
    }
}
#endif
