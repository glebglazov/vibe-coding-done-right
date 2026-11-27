import Combine

/// Keyboard-side dictation state, derived from the main app's recording state.
/// Every terminal case is published by the app on the Keyboard Channel — the
/// keyboard never infers one (ADR-0004).
enum DictationState {
    case idle
    case recording
    case transcribing
    /// Transcription text available — waiting for user tap to insert
    case ready
    /// Recording produced no speech — shown briefly before reverting to idle
    case emptyResult
    /// The app published `cancelled`: a Discard, or a stop during Arming. The
    /// DISCARDED pill shows briefly, then START comes back.
    case cancelled
    /// The run failed to produce a transcript. The reason stays in the app; the
    /// pill only reports that a failure happened.
    case failed
}

extension DictationState {
    init(_ shown: KeyboardShown) {
        switch shown {
        case .idle: self = .idle
        case .recording: self = .recording
        case .transcribing: self = .transcribing
        case .ready: self = .ready
        case .flash(_, .emptyResult): self = .emptyResult
        case .flash(_, .cancelled): self = .cancelled
        case .flash(_, .failed): self = .failed
        }
    }
}

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
    /// Source of truth for the AI pill.
    @Published var aiMode: AIPromptMode = .verbatim
    @Published var textStyle: SharedTextStyle = .casual

    /// AI mode and text style are fixed while a run listens (ADR-0010). The
    /// wire's `recording` covers Arming and Capturing alike.
    var areOutputChoicesLocked: Bool {
        dictationState == .recording
    }
}
