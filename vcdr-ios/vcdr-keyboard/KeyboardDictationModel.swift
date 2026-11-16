import Combine

/// What the keyboard's SwiftUI views render: the run's state and the output
/// choices the pills show.
///
/// It lives apart from `KeyboardViewController` so the views can observe it
/// without owning the controller. The controller owns its hosting view, and
/// the hosting view owns these views, so a view that held the controller would
/// keep every controller iOS ever built for this process alive.
@MainActor
final class KeyboardDictationModel: ObservableObject {

    /// Re-warms the haptic engine on every transition into `.transcribing`
    /// so the success impact fired from inside `stopAndWaitForResult`'s
    /// `RunLoop.main.run(until:)` poll lands on a primed engine. The keyboard
    /// extension's daemon connection goes cold quickly, so without this the
    /// insertion haptic is the most likely to drop.
    @Published var dictationState: DictationState = .idle {
        didSet {
            if dictationState == .transcribing, oldValue != .transcribing {
                KeyboardHaptics.prepare()
            }
        }
    }

    @Published var aiConfigured: Bool = false
    /// Source of truth for the AI/Verbatim pill. `.verbatim` ↔ "AI off".
    @Published var aiMode: AIPromptMode = .verbatim
    @Published var textStyle: SharedTextStyle = .casual

    /// Number of text selections captured in the current recording session (assistant mode).
    @Published var captureCount: Int = 0

    /// AI mode and text style are fixed while a run listens (ADR-0010). The
    /// wire's `recording` covers Arming and Capturing alike.
    var areOutputChoicesLocked: Bool {
        dictationState == .recording
    }
}
