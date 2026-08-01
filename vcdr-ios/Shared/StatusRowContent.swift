import Foundation

/// A transient, run-adjacent status the reserved row can carry when no hold is
/// in progress.
///
/// Deliberately a closed set rather than a free-form string: the row is one
/// line tall, permanently reserved, and shared by both surfaces, so its
/// tenants have to be enumerable and their precedence decidable in one place.
enum TransientStatus: Equatable, CaseIterable {
    case transcribing
    /// A run that finished with nothing to insert. Also the app's error
    /// message for an empty result, so the wording can't drift between the
    /// coordinator and the row.
    case noSpeechDetected

    var text: String {
        switch self {
        case .transcribing: Self.transcribingText
        case .noSpeechDetected: Self.noSpeechDetectedText
        }
    }

    static let transcribingText = "Transcribing…"
    static let noSpeechDetectedText = "No speech detected"
}

/// The one source of what the reserved row says, on both surfaces.
///
/// The row exists because the hold-Stop-to-Discard gesture is not
/// self-explanatory to someone meeting it cold: naming the gesture before it
/// starts is not enough, so while a hold runs the row narrates the escape
/// hatch and the deadline. Between holds it is the surface's general status
/// line, which is what earns it a permanently reserved height rather than a
/// conditional one.
///
/// Precedence, highest first:
/// 1. the hold narration — the only tenant with a deadline attached,
/// 2. a transient status,
/// 3. the resting Discard Hint, while a hold is possible at all,
/// 4. nothing.
@MainActor
enum StatusRowContent {

    // MARK: - Constants

    /// Shown for the whole of a run that isn't being held, and unchanged
    /// through the Discard Dwell — the dwell shows nothing new by rule
    /// (ADR-0004), and that includes this row.
    static let restingHint = "Hold STOP to discard"
    /// Names the escape hatch while the Discard Warning ramps: release is
    /// still the recovery gesture right up to the threshold.
    static let releaseHint = "Release to keep"
    private static let countdownSeparator = " · "

    // MARK: - Content

    static func resolve(
        warningProgress: CGFloat?,
        status: TransientStatus?,
        holdAvailable: Bool
    ) -> String? {
        if let warningProgress {
            return holdNarration(warningProgress: warningProgress)
        }
        if let status {
            return status.text
        }
        return holdAvailable ? restingHint : nil
    }

    /// The escape hatch plus how long is left to take it.
    static func holdNarration(warningProgress: CGFloat) -> String {
        "\(releaseHint)\(countdownSeparator)\(remainingSeconds(warningProgress: warningProgress))s"
    }

    /// Whole seconds left before Discard fires, derived from where the ramp
    /// has got to inside the warning window. There is no second timer and no
    /// second copy of the threshold: the ramp is the controller's own, the
    /// window is the controller's own constant, so the countdown cannot drift
    /// from when Discard actually fires.
    ///
    /// Floored at 1 — the ramp reaching 0 remaining *is* the threshold, and
    /// the warning is already gone by then, so "0s" would only ever be a
    /// single frame of lie.
    static func remainingSeconds(warningProgress: CGFloat) -> Int {
        let clamped = min(1, max(0, warningProgress))
        let remaining = HoldToDiscardController.warningDuration * Double(1 - clamped)
        return max(1, Int(remaining.rounded(.up)))
    }

    /// Every string the row can ever hold. The row lays all of these out
    /// invisibly so its text block is sized to the widest of them once, and
    /// content changes — a tenant swap, or the countdown ticking down — can't
    /// reflow the line.
    static var sizingTexts: [String] {
        [restingHint, holdNarration(warningProgress: 0)]
            + TransientStatus.allCases.map(\.text)
    }
}
