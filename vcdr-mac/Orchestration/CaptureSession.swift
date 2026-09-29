import Foundation
import AppKit
import OSLog

/// Unified orchestrator for the full capture lifecycle:
/// `idle → recording → transcribing → processing → (awaitingPreview | executing) → idle`.
///
/// Replaces the previous split between `RecordingCoordinator` (state machine + audio)
/// and `CaptureCoordinator` (panel + submission + history). Merging eliminates the
/// 9-method delegate protocol, the shared `SessionOverrides` observable, the smuggled
/// `pendingDestinationOverride`, and the silent `hadDestinationOverride` flag — all of
/// which previously split a single conceptual flow across six files.
///
/// Design invariants:
///
/// - Callers observe exactly one property: `status: Status`. Everything else is private.
/// - The only four entry points are `toggle()`, `cancel()`,
///   `suspendForModeSwitcher()`, and the DEBUG-only `waitForNextIdle(timeout:)`.
/// - Both the initial AI call and the user-triggered retry route through `runProcessingPipeline`
///   and thence through `AIProcessingPort`. They cannot drift.
/// - Preview skipping is expressed by one named predicate, `shouldSkipPreview(result:mode:)`,
///   whose test name IS the rule.
/// - Hotkey claims are owned internally and derived from `settings` and the phase;
///   claiming needs no accessibility grant.

// MARK: - CaptureSessionDelegate

/// Delegate protocol for observing capture session lifecycle events.
@MainActor
protocol CaptureSessionDelegate: AnyObject {
    /// Called when recording stops and transcription begins.
    func captureSessionDidStopRecording(_ session: CaptureSession)
    /// Called when a new recording session starts.
    func captureSessionDidStartRecording(_ session: CaptureSession)
}

@Observable
@MainActor
final class CaptureSession {

    // MARK: - Public types

    struct Status: Equatable {
        enum Phase: Equatable {
            case idle
            case preparingToRecord
            case recording
            case transcribing
            case awaitingPreview
            case executing
            case error(String)

            /// A capture is in flight, so `cancel()` has something to act on — and
            /// the cancel hotkey has a reason to hold its combination.
            var hasCaptureToCancel: Bool {
                switch self {
                case .preparingToRecord, .recording, .transcribing, .executing, .awaitingPreview: true
                case .idle, .error: false
                }
            }
        }
        var phase: Phase
        var statusText: String
        var menuBarIcon: String
        var canToggle: Bool
    }

    /// Test observation seam — returned by `waitForNextIdle(timeout:)`.
    /// Production code never inspects this.
    struct Outcome: Equatable {
        enum Kind: Equatable {
            case executed
            case previewShown
            case aiProcessingFallback
            case cancelled
            case failed
            case rejected
        }
        let kind: Kind
        let finalText: String?
        let destinationID: UUID?
        let historyConversationID: UUID?
    }

    /// RAII handle returned by `suspend()`. Releases suspension on deinit —
    /// callers cannot forget to "resume". Store it in a property; nil it to release.
    ///
    /// Deinit hops to the main actor via a Task because class deinit is not
    /// inherently actor-isolated under Swift 6 strict concurrency. In practice
    /// callers hold the token on a @MainActor type, so the hop is immediate.
    final class SuspensionToken: @unchecked Sendable {
        private var onRelease: (@MainActor @Sendable () -> Void)?

        fileprivate init(_ onRelease: @escaping @MainActor @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        /// Explicitly release the suspension now (idempotent).
        func release() {
            guard let handler = onRelease else { return }
            onRelease = nil
            Task { @MainActor in handler() }
        }

        deinit {
            guard let handler = onRelease else { return }
            Task { @MainActor in handler() }
        }
    }

    // MARK: - Dependencies

    struct Dependencies {
        /// Resolves the provider that runs a Transcription Model. A closure
        /// rather than a provider, because which model a run uses is a setting
        /// — the Default, or the active Mode's Transcription Override.
        let transcription: @MainActor @Sendable (TranscriptionModel) -> any TranscriptionProvider
        /// Starts preparing a Transcription Model, or joins the preparation
        /// already running. A Mode's Override may pin a model nothing has
        /// loaded this launch, and the run waits for it rather than refusing to
        /// record (`docs/adr/0006`) — so the run is what starts it.
        let prepareTranscription: @MainActor @Sendable (TranscriptionModel) -> Void
        /// Hands out the claims this session holds on its key combinations.
        let hotkeyRegistry: any HotkeyRegistry
        let audio: AudioRecorder
        let media: MediaPlaybackController
        let selectionCapturer: SelectionCapturer
        let makeClipboardMonitor: @MainActor @Sendable () -> ClipboardMonitor
        let indicator: RecordingIndicatorPanel
        let panel: any CapturePanelSurface
        let textProcessor: TextProcessor
        /// Live Substitutions list, read at submission time and applied to the
        /// dictated transcript as the pipeline's first step.
        let substitutionStore: any SubstitutionStore
        /// The session owns destination overrides per-run, but
        /// `ModeSwitcherCoordinator` + `RecordingIndicatorPanel` still need
        /// shared read/write access to parameter overrides — so the same
        /// instance is wired through dependencies rather than created here.
        let overrides: SessionOverrides
        /// Provides the effective style for the current capture.
        /// Returns the style to apply for text transformation.
        let styleProvider: @MainActor @Sendable () -> Style
    }

    // MARK: - Constants

    static let errorIndicatorDuration: Duration = .seconds(10)
    static let successIndicatorDuration: Duration = .seconds(2)
    static let pillErrorDisplayDuration: Duration = .seconds(1.5)
    static let pillFlashDuration: Duration = .seconds(1)
    static let audioSettleDelayBeforeResume: Duration = .milliseconds(300)
    /// The Preparation Heartbeat counts whole seconds, so re-reading the phase
    /// faster than this would only repeat the line already on screen.
    static let preparationNoticeInterval: Duration = .seconds(1)
    static let modelReadinessPollingInterval: Duration = .milliseconds(100)

    // MARK: - Injected state (stored for internal use)

    let settings: AppSettings
    let history: any HistoryStore
    let resolveTranscription: @MainActor @Sendable (TranscriptionModel) -> any TranscriptionProvider
    let prepareTranscription: @MainActor @Sendable (TranscriptionModel) -> Void

    /// Which Transcription Model this run uses and what it is told: the active
    /// Mode's Transcription Override, or the Default and the Default's own
    /// settings. Read at each use so that a Mode switched or a model configured
    /// mid-session applies to the next recording rather than the next launch.
    var effectiveTranscription: EffectiveTranscription {
        settings.transcriptionSettings.effectiveTranscription(for: settings.activeMode)
    }

    /// The provider for the model this run transcribes with.
    var transcription: any TranscriptionProvider {
        resolveTranscription(effectiveTranscription.model)
    }
    let hotkeyRegistry: any HotkeyRegistry
    let audio: AudioRecorder
    let media: MediaPlaybackController
    let selectionCapturer: SelectionCapturer
    let makeClipboardMonitor: @MainActor @Sendable () -> ClipboardMonitor
    let indicator: RecordingIndicatorPanel
    let panel: any CapturePanelSurface
    let textProcessor: TextProcessor
    let substitutionStore: any SubstitutionStore
    let overrides: SessionOverrides
    var styleProvider: @MainActor @Sendable () -> Style

    // MARK: - Public observable

    private(set) var status: Status = Status(
        phase: .idle,
        statusText: "Ready",
        menuBarIcon: "waveform.circle",
        canToggle: true
    )

    // MARK: - Hotkeys (owned internally)

    /// The session's claim on the toggle combination. Its lifetime *is* the
    /// hotkey's: no claim held means the combination reaches the frontmost app.
    @ObservationIgnored var toggleClaim: HotkeyClaim?

    /// The session's claim on the cancel combination, derived from the phase in
    /// `setupCancelHotkey` and nowhere else. Cancel is bound to an ordinary
    /// combination — Shift+Escape by default — so a claim held while VCDR is idle
    /// would swallow it system-wide.
    @ObservationIgnored var cancelClaim: HotkeyClaim?

    /// Set while the mode switcher is up. Its window reads Escape itself, which a
    /// standing claim on the cancel combination would consume first.
    @ObservationIgnored private(set) var isSuspendedForModeSwitcher = false

    /// The claims behind the Output Destinations' Activation Hotkeys, derived
    /// from the phase in `setupDestinationHotkeys` and nowhere else.
    @ObservationIgnored let destinationHotkey: DestinationHotkeyManager

    // MARK: - Per-run state (cleared on terminal transitions)

    struct RunState {
        let clipboardMonitor: ClipboardMonitor
        var previousActiveApp: NSRunningApplication?
        var captureTask: Task<CapturedContext?, Never>?
        var cursorContext: CursorContext?
        var captures: [CapturedContext] = []
        var destinationOverrideID: UUID?
        var hadDestinationOverride: Bool = false
        var conversationID: UUID = UUID()
        /// Observer for app activation changes during recording
        var appSwitchObserver: NSObjectProtocol?
    }

    @ObservationIgnored var run: RunState?

    /// Opaque handle from TextProcessor — stored while awaiting preview confirmation.
    @ObservationIgnored var pendingPreview: PreviewHandle?

    // MARK: - Cancellable tasks (all torn down in deinit)

    @ObservationIgnored var processingTask: Task<Void, Never>?
    /// Alive while an unready model still holds the run up. Its liveness is also
    /// how cancellation knows the user is discarding a recording rather than
    /// escaping a hang.
    @ObservationIgnored var preparationNarrationTask: Task<Void, Never>?
    @ObservationIgnored var immediateActionTask: Task<Void, Never>?
    @ObservationIgnored var autoDismissTask: Task<Void, Never>?
    @ObservationIgnored var pillResetTask: Task<Void, Never>?

    @ObservationIgnored var recordingStartInstant: ContinuousClock.Instant?

    // MARK: - Delegate

    @ObservationIgnored weak var delegate: CaptureSessionDelegate?

    // MARK: - Test observation

    @ObservationIgnored private var lastOutcome: Outcome?

    // MARK: - Init

    init(
        settings: AppSettings,
        history: any HistoryStore,
        deps: Dependencies
    ) {
        self.settings = settings
        self.history = history
        self.resolveTranscription = deps.transcription
        self.prepareTranscription = deps.prepareTranscription
        self.hotkeyRegistry = deps.hotkeyRegistry
        self.audio = deps.audio
        self.media = deps.media
        self.selectionCapturer = deps.selectionCapturer
        self.makeClipboardMonitor = deps.makeClipboardMonitor
        self.indicator = deps.indicator
        self.panel = deps.panel
        self.textProcessor = deps.textProcessor
        self.substitutionStore = deps.substitutionStore
        self.overrides = deps.overrides
        self.styleProvider = deps.styleProvider
        self.destinationHotkey = DestinationHotkeyManager(registry: deps.hotkeyRegistry)
        wirePanelCallbacks()
        wireDestinationHotkeys()
        observeHotkeySettings()
        // Claiming a combination needs no Accessibility grant, so the toggle is
        // live from launch rather than from whenever the grant arrives.
        setupToggleHotkey()
    }

    deinit {
        preparationNarrationTask?.cancel()
        processingTask?.cancel()
        immediateActionTask?.cancel()
        autoDismissTask?.cancel()
        pillResetTask?.cancel()
    }

    // MARK: - Style Provider

    /// Updates the style provider after initialization.
    /// Used to break initialization circularity with AppDependencies.
    func setStyleProvider(_ provider: @MainActor @Sendable @escaping () -> Style) {
        self.styleProvider = provider
    }

    // MARK: - Public API

    /// Global toggle hotkey entry point. Behavior depends on current phase:
    /// - `.idle` / `.error`         → start recording
    /// - `.recording`               → stop and transcribe
    /// - `.awaitingPreview`         → confirm preview with default destination
    /// - other transient phases     → no-op (may emit a reject buzz)
    func toggle() {
        switch status.phase {
        case .idle, .error:
            Task { await startRecording() }
        case .recording:
            stopRecordingAndTranscribe()
        case .awaitingPreview:
            confirmPreview()
        case .preparingToRecord, .transcribing, .executing:
            // Re-entrant press — indicate rejection.
            panel.buzz()
            emit(.rejected, finalText: nil, destinationID: nil, historyConversationID: nil)
        }
    }

    /// Esc or menu bar "Cancel". Cancels whatever is happening and returns to idle.
    func cancel() {
        switch status.phase {
        case .idle:
            return
        case .preparingToRecord, .recording, .transcribing:
            cancelRecording()
        case .awaitingPreview, .executing:
            cancelCapture()
        case .error:
            clearError()
        }
    }

    /// Mode switcher asks us to step out of the way: the capture itself keeps
    /// running, but the cancel combination goes back so the switcher's own Escape
    /// reaches it, and a visible panel dims. Returns an RAII token; releasing it
    /// restores both. Safe to call repeatedly — nesting is not supported (prior
    /// tokens are independent).
    func suspendForModeSwitcher() -> SuspensionToken {
        isSuspendedForModeSwitcher = true
        setupCancelHotkey()
        let wasVisible = panel.isVisible
        if wasVisible {
            panel.setSuspendedForModeSwitcher(true)
        }

        return SuspensionToken { [weak self] in
            guard let self else { return }
            if wasVisible {
                self.panel.setSuspendedForModeSwitcher(false)
            }
            self.isSuspendedForModeSwitcher = false
            self.setupCancelHotkey()
        }
    }

    /// DEBUG / test-only: poll until the session reaches a resting phase
    /// (`.idle`, `.error`, or `.awaitingPreview`) and return the last emitted
    /// outcome. Returns nil on timeout.
    @discardableResult
    func waitForNextIdle(timeout: Duration = .seconds(10)) async -> Outcome? {
        let start = ContinuousClock.now
        let pollInterval: Duration = .milliseconds(20)
        while start.duration(to: .now) < timeout {
            switch status.phase {
            case .idle, .error, .awaitingPreview:
                let outcome = lastOutcome
                lastOutcome = nil
                return outcome
            default:
                try? await Task.sleep(for: pollInterval)
            }
        }
        return nil
    }

    // MARK: - Internal helpers

    func setStatus(_ phase: Status.Phase) {
        let old = status.phase
        status = Status(
            phase: phase,
            statusText: Self.statusText(for: phase),
            menuBarIcon: Self.menuBarIcon(for: phase),
            canToggle: Self.canToggle(for: phase)
        )
        // The only place the phase-derived claims are decided. Every phase change
        // passes through here, so no exit path — including the error branches —
        // can strand a claim or forget to make it.
        setupCancelHotkey()
        setupDestinationHotkeys()
        if old != phase {
            Logger.consistency.info("Session phase: \(String(describing: old)) → \(String(describing: phase))")
        }
    }

    /// Records an outcome so the next `waitForNextIdle` call can return it.
    /// Only the most recent outcome is retained.
    func emit(_ kind: Outcome.Kind, finalText: String?, destinationID: UUID?, historyConversationID: UUID?) {
        lastOutcome = Outcome(
            kind: kind,
            finalText: finalText,
            destinationID: destinationID,
            historyConversationID: historyConversationID
        )
    }

    private func wirePanelCallbacks() {
        panel.onFocusLost = { [weak self] in
            self?.dismissOverlay()
        }
        panel.onConfirm = { [weak self] in
            self?.confirmPreview()
        }
        panel.onCancelCapture = { [weak self] in
            self?.cancel()
        }
        panel.onDestinationSubmit = { [weak self] destinationID in
            self?.confirmPreviewWithDestination(destinationID)
        }
        panel.onRetryAIProcessing = { [weak self] in
            self?.retryAIProcessing()
        }
    }

    private func wireDestinationHotkeys() {
        destinationHotkey.onDestinationMatched = { [weak self] destinationID in
            guard let self else { return }
            // Smuggle the override into the current run so it's consumed when transcription finishes.
            self.run?.destinationOverrideID = destinationID
            self.stopRecordingAndTranscribe()
        }
    }

    private func clearError() {
        setStatus(.idle)
    }

    // MARK: - Status derivation

    private static func statusText(for phase: Status.Phase) -> String {
        switch phase {
        case .idle: "Ready"
        case .preparingToRecord: "Starting..."
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .awaitingPreview: "Confirm..."
        case .executing: "Executing..."
        case .error(let msg): "Error: \(msg)"
        }
    }

    private static func menuBarIcon(for phase: Status.Phase) -> String {
        switch phase {
        case .idle: "waveform.circle"
        case .preparingToRecord: "waveform.circle"
        case .recording: "waveform.circle.fill"
        case .transcribing, .executing: "ellipsis.circle"
        case .awaitingPreview: "eye.circle"
        case .error: "exclamationmark.circle"
        }
    }

    private static func canToggle(for phase: Status.Phase) -> Bool {
        switch phase {
        case .idle, .preparingToRecord, .recording, .awaitingPreview, .error: true
        case .transcribing, .executing: false
        }
    }
}
