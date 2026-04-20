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
    let transcriptionHistory: any HistoryStore
    let styleRegistry: StyleRegistry
    let frontmostAppMonitor: FrontmostAppMonitor
    let styleResolutionPipeline: StyleResolutionPipeline
    let styleOverrideController: StyleOverrideController
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let copyLatestCaptureHandler: CopyLatestCaptureHandler

    /// The currently effective style (observable for UI updates).
    var currentStyle: Style { styleOverrideController.currentEffectiveStyle }

    /// Whether a style override is currently active.
    var hasStyleOverride: Bool { styleOverrideController.isOverridden }

    #if DEBUG
    let audioRecorder: AudioRecorder
    #endif

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Loading model..."
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
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        let mediaPlayback = MediaPlaybackController()
        self.mediaPlaybackController = mediaPlayback
        let defaults = UserDefaults.standard
        let syncEnabled = HistoryStoreFactory.effectiveSyncEnabled(defaults: defaults)
        HistoryMigrator.reconcileAtLaunch(syncEnabled: syncEnabled)
        let history = HistoryStoreFactory.make(defaults: defaults)
        self.transcriptionHistory = history
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

        // Initialize style-related components first
        self.styleRegistry = StyleRegistry()
        self.frontmostAppMonitor = FrontmostAppMonitor()
        self.styleResolutionPipeline = StyleResolutionPipeline(
            styleRegistry: styleRegistry,
            frontmostAppMonitor: frontmostAppMonitor
        )

        self.styleOverrideController = StyleOverrideController(
            availableStyles: Style.builtIn,
            initialDetectedStyle: Style.casual
        )

        self.modeSwitcherCoordinator = ModeSwitcherCoordinator(
            settings: settings,
            overrides: overrides,
            styleOverrideController: styleOverrideController
        )

        self.copyLatestCaptureHandler = CopyLatestCaptureHandler(
            settings: settings,
            transcriptionHistory: history,
            recordingIndicator: recordingIndicator
        )

        // Create capture panel early so it's available for session initialization and delegate wiring
        let capturePanel = CapturePanel()

        // TextProcessor owns the processing pipeline — injected into the session.
        // styleProvider will be updated after init to break the circular reference.
        let textProcessor = TextProcessor(
            aiPort: AIProcessingAdapter(),
            history: history,
            settings: settings,
            overrides: overrides,
            styleProvider: { .casual }  // Temporary, will be updated after init
        )

        // Session initialization (comes after styleOverrideController due to delegate dependency)
        // Note: styleProvider will be set after initialization to avoid circular reference
        let captureSession = CaptureSession(
            settings: settings,
            history: history,
            deps: .init(
                transcription: provider,
                audio: audioRecorder,
                media: mediaPlayback,
                selectionCapturer: selectionCapturer,
                clipboardMonitor: clipboardMonitor,
                indicator: recordingIndicator,
                panel: CapturePanelAdapter(capturePanel),
                textProcessor: textProcessor,
                overrides: overrides,
                styleProvider: { .casual }  // Temporary, will be updated after init
            )
        )
        self.session = captureSession

        // Wire up delegates (must happen after all properties are initialized for @Observable)
        captureSession.delegate = self
        modeSwitcherCoordinator.delegate = self
        setupStyleOverrideIntegration()
        setupStyleResolutionCallbacks()

        // Update the style provider now that self is fully initialized
        let styleProviderClosure: @MainActor @Sendable () -> Style = { [weak self] in
            self?.styleOverrideController.currentEffectiveStyle ?? .casual
        }
        captureSession.setStyleProvider(styleProviderClosure)
        textProcessor.setStyleProvider(styleProviderClosure)
    }

    // MARK: - Style Override Integration

    private func setupStyleOverrideIntegration() {
        // Wire StyleOverrideController to FrontmostAppMonitor
        // Clear override when frontmost app changes
        frontmostAppMonitor.onPermissionChanged = { [weak self] _ in
            // Permission changes don't directly affect override
        }

        // Set up style change callback to update SessionOverrides
        styleOverrideController.onStyleChanged = { [weak self] newStyle in
            guard let self else { return }
            // Update SessionOverrides to reflect the current effective style
            if self.styleOverrideController.isOverridden {
                self.session.overrides.styleOverride = newStyle.id
            } else {
                self.session.overrides.styleOverride = nil
            }
            Logger.styles.debug("Effective style updated: \(newStyle.name)")
        }
    }

    // MARK: - Style Resolution Setup

    private func setupStyleResolutionCallbacks() {
        styleResolutionPipeline.onAccessibilityPermissionChanged = { [weak self] granted in
            guard let self else { return }
            if !granted {
                Logger.app.warning("Accessibility permission denied for style resolution")
            }
        }

        // Wire pipeline style changes to update the detected style in override controller
        styleResolutionPipeline.onStyleChanged = { [weak self] newStyle in
            guard let self else { return }
            // Update the detected style in the override controller
            // This will also clear any active override (per acceptance criteria)
            self.styleOverrideController.updateDetectedStyle(newStyle)
        }
    }

    /// Sets a temporary style override (from menu bar or style switcher).
    /// Updates both SessionOverrides and the resolution pipeline.
    /// - Parameter styleID: The style ID to override with, or nil to clear.
    func setStyleOverride(_ styleID: UUID?) {
        if let styleID {
            // Find the style and activate override
            Task {
                if let style = await styleRegistry.style(withID: styleID) {
                    await MainActor.run {
                        self.styleOverrideController.activateOverride(style)
                        self.session.overrides.styleOverride = styleID
                        self.styleResolutionPipeline.setStyleOverride(styleID)
                    }
                }
            }
        } else {
            styleOverrideController.clearOverride()
            session.overrides.styleOverride = nil
            styleResolutionPipeline.clearOverride()
        }
    }

    /// Clears the active style override.
    func clearStyleOverride() {
        setStyleOverride(nil)
    }

    /// Suppresses every app-owned hotkey (global CGEvent taps + destination bindings)
    /// while the user is recording a new shortcut in the UI. Suppressed hotkeys
    /// pass through unconsumed so the key press reaches the shortcut recorder
    /// and nothing in the app reacts to it.
    @MainActor
    func setHotkeySuppression(_ suppressed: Bool) {
        session.toggleHotkey.isSuppressed = suppressed
        session.cancelHotkey.isSuppressed = suppressed
        session.destinationHotkey.isSuppressed = suppressed
        modeSwitcherCoordinator.setHotkeySuppressed(suppressed)
        copyLatestCaptureHandler.setHotkeySuppressed(suppressed)
    }

    func initialize() async {
        // Check tool availability and create template modes (async to avoid blocking main thread)
        await settings.refreshTemplateAvailability()

        // Fetch updated prompts from server in background (non-blocking)
        Task.detached {
            await PromptFetcher.refreshIfNeeded()
        }

        // Pre-resolve the MediaRemote backend so the first recording doesn't
        // pay the probe/IPC cost on the hot path.
        Task { [mediaPlaybackController] in
            await mediaPlaybackController.prewarmBackend()
        }

        checkPermissions()
        isInitialized = true
        startPermissionPolling()

        // Register hotkeys immediately — don't wait for model loading.
        // `CaptureSession.toggle()` guards on transcription readiness internally,
        // so hotkeys pressed before the model is ready show an appropriate error.
        if hasAccessibilityPermission {
            session.accessibilityGranted()
            modeSwitcherCoordinator.setupHotkey()
            copyLatestCaptureHandler.setupHotkey()
        }

        // Start style resolution pipeline
        await styleResolutionPipeline.start()

        do {
            // Poll the provider's init phase so the UI updates in real time
            let phasePoller = Task {
                while !Task.isCancelled {
                    let phase = await transcriptionProvider.initPhase
                    switch phase {
                    case .notStarted, .downloading:
                        initializationStatus = "Downloading model..."
                    case .compiling:
                        initializationStatus = "Compiling model..."
                    case .ready:
                        break
                    }
                    try? await Task.sleep(for: Self.phasePollingInterval)
                }
            }

            try await transcriptionProvider.initialize()
            phasePoller.cancel()

            isTranscriptionReady = true
            initializationStatus = "Ready"
            Logger.app.info("App fully initialized")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Initialization failed: \(error)")
        }
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

            // Register hotkeys as soon as accessibility is granted
            if !wasAccessible && self.hasAccessibilityPermission {
                self.session.accessibilityGranted()
                self.modeSwitcherCoordinator.setupHotkey()
                self.copyLatestCaptureHandler.setupHotkey()
                Logger.app.info("Accessibility granted, hotkeys registered")
            }

            // Stop polling once both permissions are granted
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
        modeSwitcherSuspension = session.suspend()
    }

    func modeSwitcherDidHide() {
        modeSwitcherSuspension = nil
    }
}

// MARK: - CaptureSessionDelegate

extension AppDependencies: CaptureSessionDelegate {

    func captureSessionDidStartRecording(_ session: CaptureSession) {
        // Recording started - no action needed for style override
        Logger.recording.info("Capture session started recording")
    }

    func captureSessionDidStopRecording(_ session: CaptureSession) {
        // Clear style override when recording stops (per acceptance criteria)
        // This ensures the next recording session starts with fresh detection
        if styleOverrideController.isOverridden {
            styleOverrideController.clearOverride()
            session.overrides.styleOverride = nil
            styleResolutionPipeline.clearOverride()
            Logger.styles.info("Style override cleared due to recording stop")
        }
    }
}
