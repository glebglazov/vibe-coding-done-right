import Foundation

/// Where the value in one settings control came from, and what can be done
/// about it. The effective settings a Mode records with are computed rather
/// than stored, so a Mode's screen has to account for every value it shows —
/// that provenance is the transparency the Override exists for.
enum TranscriptionSettingOrigin {
    /// The family's own settings screen: the value is the family's own, and
    /// there is nothing above it to have come from.
    case theFamilysOwn
    /// A Mode that has not set this: the value is the family's, and editing the
    /// family's own settings changes it here too.
    case inherited(from: TranscriptionModelFamily)
    /// A Mode that has set this for itself, and the way to give it back.
    case setByThisMode(useInherited: () -> Void)

    /// What the control says about where its value came from, or nil when there
    /// is nowhere else it could have come from.
    var label: String? {
        switch self {
        case .theFamilysOwn: nil
        case .inherited(let family): "From \(family.displayName) settings"
        case .setByThisMode: "Set by this Mode"
        }
    }
}
