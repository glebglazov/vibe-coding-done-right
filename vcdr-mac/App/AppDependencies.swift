import Combine
import SwiftUI
import AVFoundation
import ApplicationServices
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    /// Every Transcription Model's provider, kept for the process lifetime.
    private let transcriptionProviders: TranscriptionProviderRegistry
    /// What this device has installed, and where a model is added or removed.
    let transcriptionLibrary: TranscriptionLibrary
    let session: CaptureSession
    let audioDeviceMonitor: AudioDeviceMonitor
    let inputLevelMonitor: InputLevelMonitor
    let mediaPlaybackController: MediaPlaybackController
    let transcriptionHistory: HistoryStoreProxy
    let substitutionStore: SubstitutionStoreProxy
    let styleRegistry: StyleRegistry
    let frontmostAppMonitor: FrontmostAppMonitor
    let styleResolution: StyleResolutionPipeline
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let copyLatestCaptureHandler: CopyLatestCaptureHandler
    let hotkeyRegistry = SuspendableHotkeyRegistry(wrapping: CarbonHotkeyRegistry())

    #if DEBUG
    let audioRecorder: AudioRecorder
    #endif

    /// The container both datasets sync through, watched once. Each dataset
    /// keeps its own reconciler — its own toggle, its own Last Sync Time — and
    /// hears only about the Record Files its own folder holds.
    private let containerWatcher = ContainerWatcher()

    /// Owns the iCloud transport for history. Nil while history is still
    /// bootstrapping, and for as long as the sync toggle is off.
    private(set) var historySync: SyncReconciler?
    /// Owns the iCloud transport for Substitutions, and keeps it alive: nothing
    /// else holds the reconciler, and no screen reads its state — Substitutions
    /// converge without announcing it.
    private(set) var substitutionSync: SyncReconciler?

    private(set) var readiness: ModelReadiness =
        .preparing(label: ModelPreparationPhase.initialLabel)
    var isTranscriptionReady: Bool { readiness == .ready }

    /// The provider for the Default Transcription Model, resolved at each use:
    /// the Default is a setting, and reading it late is what makes a change to
    /// it apply to the next recording rather than to the next launch.
    var transcriptionProvider: any TranscriptionProvider {
        transcriptionProviders.provider(for: settings.transcriptionSettings.defaultModel)
    }

    private(set) var hasMicrophonePermission = false
    private(set) var hasAccessibilityPermission = false
    private(set) var isInitialized = false

    var needsPermissionAttention: Bool {
        !hasMicrophonePermission || !hasAccessibilityPermission
    }

    private var permissionTimer: Timer?

    /// Narrates the preparation currently on screen. A model chosen while
    /// another is still preparing leaves that one downloading — the bytes are
    /// paid for either way — but it must stop speaking for the app's readiness.
    @ObservationIgnored private var phasePoller: Task<Void, Never>?

    /// Holds the active mode-switcher suspension token. Nilling it releases the
    /// suspension via `SuspensionToken`'s RAII deinit.
    @ObservationIgnored fileprivate var modeSwitcherSuspension: CaptureSession.SuspensionToken?

    init() {
        let settings = AppSettings(secretStore: KeychainSecretStore())
        self.settings = settings
        let transcriptionProviders = TranscriptionProviderRegistry()
        self.transcriptionProviders = transcriptionProviders
        let transcriptionLibrary = TranscriptionLibrary(
            models: TranscriptionProviderRegistry.offeredModels,
            provider: { transcriptionProviders.provider(for: $0) },
            settings: settings
        )
        self.transcriptionLibrary = transcriptionLibrary
        let mediaPlayback = MediaPlaybackController()
        self.mediaPlaybackController = mediaPlayback
        let history = HistoryStoreProxy()
        self.transcriptionHistory = history
        let substitutions = SubstitutionStoreProxy()
        self.substitutionStore = substitutions
        let audioRecorder = AudioRecorder()
        #if DEBUG
        self.audioRecorder = audioRecorder
        #endif
        let overrides = SessionOverrides()
        let recordingIndicator = RecordingIndicatorPanel(
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        )
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()
        self.audioDeviceMonitor = AudioDeviceMonitor(settings: settings, skipHardware: vcdrApp.isTestHost)
        self.inputLevelMonitor = InputLevelMonitor()

        self.styleRegistry = StyleRegistry()
        self.frontmostAppMonitor = FrontmostAppMonitor()
        self.styleResolution = StyleResolutionPipeline(
            styleRegistry: styleRegistry,
            frontmostAppMonitor: frontmostAppMonitor
        )

        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(
            settings: settings,
            hotkeyRegistry: hotkeyRegistry,
            overrides: overrides,
            styleResolution: styleResolution
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            hotkeyRegistry: hotkeyRegistry,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        let capturePanel = CapturePanel()

        let textProcessor = TextProcessor(
            aiPort: AIProcessingAdapter(),
            history: history,
            settings: settings,
            overrides: overrides,
            styleProvider: { .casual }
        )

        let captureSession = CaptureSession(
            settings: settings,
            history: history,
            deps: .init(
                transcription: { transcriptionProviders.provider(for: $0) },
                // Installing a model is the download and the load — what
                // preparing it means — so a run that needs one nobody has
                // prepared asks the Library for it rather than for a second
                // preparation of its own. Awaited: a run is holding audio for
                // this model, so it goes ahead of any model nothing waits on.
                prepareTranscription: { transcriptionLibrary.install($0, urgency: .awaited) },
                hotkeyRegistry: hotkeyRegistry,
                audio: audioRecorder,
                media: mediaPlayback,
                selectionCapturer: selectionCapturer,
                clipboardMonitor: clipboardMonitor,
                indicator: recordingIndicator,
                panel: CapturePanelAdapter(capturePanel),
                textProcessor: textProcessor,
                substitutionStore: substitutions,
                overrides: overrides,
                styleProvider: { .casual }
            )
        )
        self.session = captureSession

        captureSession.delegate = self
        modeSwitcherCoordinator.delegate = self

        let styleProviderClosure: @MainActor @Sendable () -> Style = { [weak self] in
            self?.styleResolution.currentStyle ?? .casual
        }
        captureSession.setStyleProvider(styleProviderClosure)
        textProcessor.setStyleProvider(styleProviderClosure)
    }

    /// Hands every app-owned combination back to the system while the user is
    /// recording a new shortcut, so the key press reaches the shortcut recorder
    /// and nothing in the app reacts to it. Whoever opened the recorder holds the
    /// token; the claims come back when it goes away, not when someone remembers.
    @MainActor
    func suspendHotkeys() -> HotkeySuspension {
        hotkeyRegistry.suspend()
    }

    func initialize() async {
        await settings.refreshTemplateAvailability()

        Task.detached {
            await PromptFetcher.refreshIfNeeded()
        }

        // Probing MediaRemote triggers the macOS "access data from other apps"
        // prompt, so only prewarm when the pause feature can actually run.
        // resolveBackend() resolves lazily on first pause if this is skipped.
        if settings.audioSettings.pauseMediaDuringRecording {
            Task { [mediaPlaybackController] in
                await mediaPlaybackController.prewarmBackend()
            }
        }

        checkPermissions()
        isInitialized = true
        startPermissionPolling()

        await styleResolution.start()

        // Shell-first Initialization: deferred backend init.
        // History store and audio device enumeration must not block the shell.
        await bootstrapHistory()
        await bootstrapSubstitutions()
        await audioDeviceMonitor.start()

        // Reading the Library is disk work — sizing every install — and nothing
        // waits on it, so it runs beside the Default's preparation rather than
        // in front of it. Which models are installed, and which of them this Mac
        // can install, is then known before the Transcription tab is opened.
        Task { [transcriptionLibrary] in
            await transcriptionLibrary.refresh()
        }

        await prepareTranscriptionModel(transcriptionProvider)
    }

    /// The action a Preparation Failure carries: run preparation again from
    /// the start. Only a failed model has anything to retry — a run already
    /// under way narrates itself.
    func retryModelPreparation() async {
        guard case .failed = readiness else { return }
        readiness = .preparing(label: ModelPreparationPhase.initialLabel)
        await prepareTranscriptionModel(transcriptionProvider)
    }

    /// Makes `model` the Default Transcription Model and prepares it. The model
    /// being left behind keeps everything it loaded, so choosing it again later
    /// is not a second download or a second compile.
    func selectDefaultModel(_ model: TranscriptionModel) async {
        guard settings.transcriptionSettings.defaultModel != model else { return }
        settings.transcriptionSettings.defaultModel = model

        // The new model's own phase, before preparation starts: one already
        // resident is ready now, and readiness left carrying the old model's
        // answer would say Ready over a download that has not begun.
        let provider = transcriptionProvider
        var narrator = ModelPreparationNarrator()
        readiness = narrator.readiness(for: await provider.initPhase)
        await prepareTranscriptionModel(provider)
    }

    /// Runs model initialization and keeps `readiness` telling the truth about
    /// it throughout — the phase while it runs, and what stopped it if it stops.
    private func prepareTranscriptionModel(_ provider: any TranscriptionProvider) async {
        self.phasePoller?.cancel()
        let phasePoller = Task {
            // `readiness` is @Observable: writing it unconditionally at the
            // poll cadence re-evaluates every SwiftUI body that reads it,
            // so only the polls that change the visible line are published.
            var narrator = ModelPreparationNarrator()
            while !Task.isCancelled {
                let phase = await provider.initPhase
                let polled = narrator.readiness(for: phase)
                if polled != readiness {
                    readiness = polled
                }
                try? await Task.sleep(for: Self.phasePollingInterval)
            }
        }
        self.phasePoller = phasePoller

        do {
            // Nothing is waiting on this one: the Default is warmed so the
            // first recording finds it ready, and a model some recording is
            // already held up by must be let past it.
            try await provider.initialize(urgency: .unawaited)
            phasePoller.cancel()

            guard isDefault(provider) else { return }
            readiness = .ready
            Logger.app.info("App fully initialized")
        } catch {
            phasePoller.cancel()
            guard isDefault(provider) else { return }
            readiness = .failed(from: error)
            Logger.app.error("Initialization failed: \(error)")
        }
    }

    /// Whether this provider still runs the Default Transcription Model. A
    /// preparation outlives the choice that started it whenever the user picks
    /// another model mid-download, and the one it finishes is not the one the
    /// readiness surfaces are describing.
    private func isDefault(_ provider: any TranscriptionProvider) -> Bool {
        provider.model == settings.transcriptionSettings.defaultModel
    }

    /// Deferred history bootstrap: opens the Local Store off-main, then
    /// installs it on the main actor from that Sendable snapshot. Writes that
    /// arrived before the store was ready are queued in the proxy and flushed
    /// once the real store is set.
    ///
    /// The reconciler comes after, on its own task: it resolves the iCloud
    /// container, which blocks for seconds on a first launch, and nothing that
    /// reads history waits for it.
    private func bootstrapHistory() async {
        let snapshot: LocalHistoryStore.Snapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                try LocalHistoryStore.loadSnapshot()
            }.value
        } catch {
            Logger.app.error("History store unavailable: \(error)")
            return
        }

        let store = LocalHistoryStore(snapshot: snapshot)
        await transcriptionHistory.setRealStore(store)

        historySync = SyncReconciler.startIfEnabled(
            store: store,
            dataset: HistorySync.dataset,
            defaults: UserDefaults.standard,
            watcher: containerWatcher
        )
    }

    /// Deferred Substitutions bootstrap, mirroring `bootstrapHistory`: opens the
    /// Local Store off-main, then installs the real store on the main actor
    /// from that Sendable snapshot — flushing any edits the user made before
    /// the store was ready. Nothing on this path asks iCloud anything; the
    /// reconciler links the record files behind a list that already answers.
    private func bootstrapSubstitutions() async {
        let snapshot: LocalSubstitutionStore.Snapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                try LocalSubstitutionStore.loadSnapshot()
            }.value
        } catch {
            Logger.app.error("Substitution store unavailable: \(error)")
            return
        }

        let store = LocalSubstitutionStore(snapshot: snapshot)
        substitutionStore.setRealStore(store)

        substitutionSync = SyncReconciler.startIfEnabled(
            store: store,
            dataset: SubstitutionSync.dataset,
            defaults: UserDefaults.standard,
            watcher: containerWatcher
        )
    }

    private func checkPermissions() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    // MARK: - Constants

    private static let phasePollingInterval: Duration = .milliseconds(200)
    private static let permissionPollInterval: TimeInterval = 2

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionPollInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let wasAccessible = self.hasAccessibilityPermission
            self.checkPermissions()

            if !wasAccessible && self.hasAccessibilityPermission {
                Logger.app.info("Accessibility granted; simulated paste is available")
            }

            if self.hasMicrophonePermission && self.hasAccessibilityPermission {
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
    }

    deinit {
        permissionTimer?.invalidate()
    }
}

// MARK: - ModeSwitcherCoordinatorDelegate

extension AppDependencies: ModeSwitcherCoordinatorDelegate {

    var isRecordingActive: Bool {
        if case .recording = session.status.phase { return true }
        return false
    }

    func modeSwitcherWillShow() {
        modeSwitcherSuspension = session.suspendForModeSwitcher()
    }

    func modeSwitcherDidHide() {
        modeSwitcherSuspension = nil
    }
}

// MARK: - CaptureSessionDelegate

extension AppDependencies: CaptureSessionDelegate {

    func captureSessionDidStartRecording(_ session: CaptureSession) {
        Logger.recording.info("Capture session started recording")
    }

    func captureSessionDidStopRecording(_ session: CaptureSession) {
        // Style Override persists for the app run — not tied to Capture Session lifecycle.
    }
}
