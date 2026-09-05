import Combine
import SwiftUI
import AVFoundation
import ApplicationServices
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
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

    /// Owns the iCloud transport for history. Nil while history is still
    /// bootstrapping, and for as long as the sync toggle is off.
    private(set) var historySync: HistorySyncReconciler?

    private(set) var readiness: ModelReadiness =
        .preparing(label: ModelPreparationPhase.initialLabel)
    var isTranscriptionReady: Bool { readiness == .ready }
    private(set) var hasMicrophonePermission = false
    private(set) var hasAccessibilityPermission = false
    private(set) var isInitialized = false

    var needsPermissionAttention: Bool {
        !hasMicrophonePermission || !hasAccessibilityPermission
    }

    private var permissionTimer: Timer?

    /// Holds the active mode-switcher suspension token. Nilling it releases the
    /// suspension via `SuspensionToken`'s RAII deinit.
    @ObservationIgnored fileprivate var modeSwitcherSuspension: CaptureSession.SuspensionToken?

    init() {
        let settings = AppSettings(secretStore: KeychainSecretStore())
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
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
                transcription: provider,
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

        await prepareTranscriptionModel()
    }

    /// The action a Preparation Failure carries: run preparation again from
    /// the start. Only a failed model has anything to retry — a run already
    /// under way narrates itself.
    func retryModelPreparation() async {
        guard case .failed = readiness else { return }
        readiness = .preparing(label: ModelPreparationPhase.initialLabel)
        await prepareTranscriptionModel()
    }

    /// Runs model initialization and keeps `readiness` telling the truth about
    /// it throughout — the phase while it runs, and what stopped it if it stops.
    private func prepareTranscriptionModel() async {
        let phasePoller = Task {
            // `readiness` is @Observable: writing it unconditionally at the
            // poll cadence re-evaluates every SwiftUI body that reads it,
            // so only the polls that change the visible line are published.
            var narrator = ModelPreparationNarrator()
            while !Task.isCancelled {
                let phase = await transcriptionProvider.initPhase
                let polled = narrator.readiness(for: phase)
                if polled != readiness {
                    readiness = polled
                }
                try? await Task.sleep(for: Self.phasePollingInterval)
            }
        }

        do {
            try await transcriptionProvider.initialize()
            phasePoller.cancel()

            readiness = .ready
            Logger.app.info("App fully initialized")
        } catch {
            phasePoller.cancel()
            readiness = .failed(from: error)
            Logger.app.error("Initialization failed: \(error)")
        }
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

        historySync = HistorySyncReconciler.startIfEnabled(
            store: store,
            defaults: UserDefaults.standard
        )
    }

    /// Deferred Substitutions bootstrap, mirroring `bootstrapHistory`: resolves
    /// the iCloud ubiquity container and loads the store snapshot off-main
    /// (can block for seconds on first launch), then installs the real store
    /// on the main actor from that Sendable snapshot — flushing any edits the
    /// user made before the store was ready.
    private func bootstrapSubstitutions() async {
        let defaults = UserDefaults.standard
        let syncEnabled = SubstitutionStoreFactory.effectiveSyncEnabled(defaults: defaults)

        let bootstrap = await Task.detached(priority: .userInitiated) {
            let root = UbiquitySubstitutionStore.resolveStorageRoot()
            return SubstitutionStoreFactory.loadBootstrap(syncEnabled: syncEnabled, ubiquityRoot: root)
        }.value

        let store = SubstitutionStoreFactory.make(bootstrap)
        substitutionStore.setRealStore(store)
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
