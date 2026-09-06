import Foundation
@testable import vcdr_mac

/// Harness for `CaptureSession` tests — constructs a session with all
/// local-substitutable dependencies as real instances and the two ports
/// (`CapturePanelSurface`, `AIProcessingPort`) as fakes.
///
/// Tests interact through `session` and assert against `fakePanel.calls` /
/// `scriptedAI.receivedCalls` / `history.conversations`.
@MainActor
struct CaptureSessionTestEnvironment {

    // MARK: - Constants

    private static let stateTimeout: Duration = .seconds(10)
    private static let statePollingInterval: Duration = .milliseconds(20)

    let session: CaptureSession
    let settings: AppSettings
    let history: FileHistoryStore
    let fakePanel: FakeCapturePanel
    let scriptedAI: ScriptedAIProcessing
    let mockProvider: MockTranscriptionProvider
    /// The provider behind the other Transcription Model, so a test can change
    /// the Default the way the settings screen does and see which of the two
    /// the next recording reaches.
    let alternateProvider: MockTranscriptionProvider
    let audioRecorder: AudioRecorder
    let textProcessor: TextProcessor
    let hotkeyRegistry: FakeHotkeyRegistry
    /// What the session actually claims through, so a test can suspend every
    /// claim the way the shortcut recorder does.
    let suspendableRegistry: SuspendableHotkeyRegistry

    private let userDefaultsSuiteName: String

    /// Creates a test environment wired with a copy-to-clipboard default destination so
    /// the default "paste" code path (which needs CGEvent accessibility) never runs.
    init(
        mockProvider: MockTranscriptionProvider = MockTranscriptionProvider(),
        alternateProvider: MockTranscriptionProvider = MockTranscriptionProvider(model: .whisperLargeV3Turbo),
        testAudioFileName: String = "short.wav",
        aiResults: [Result<String, Error>] = [],
        modePreview: Bool = false,
        modeProcessing: ProcessingType = .none
    ) {
        self.mockProvider = mockProvider
        self.alternateProvider = alternateProvider
        self.scriptedAI = ScriptedAIProcessing(results: aiResults)

        let suiteName = "vcdr.test.\(UUID().uuidString)"
        self.userDefaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(userDefaults: defaults, secretStore: InMemorySecretStore())
        // Disable media pause to avoid hanging on MediaRemoteClient resolution in tests.
        settings.audioSettings = AudioSettings(preferredInputDeviceID: nil, pauseMediaDuringRecording: false)
        // Disable filler word removal so raw mock text comes through unchanged.
        settings.removeFillerWords = false

        // Configure the active mode to use the built-in Copy destination so tests don't
        // exercise CGEvent accessibility for simulated Cmd+V. Also apply any test-requested
        // preview / processing flags so the same harness can cover every branch.
        var mode = settings.activeMode
        mode.defaultOutputDestinationID = OutputDestination.builtInCopyID
        mode.showPreview = modePreview
        mode.processingType = modeProcessing
        mode.promptType = .custom
        mode.systemPrompt = "test prompt"
        if let idx = settings.modes.firstIndex(where: { $0.id == mode.id }) {
            settings.modes[idx] = mode
        } else {
            settings.modes = [mode]
            settings.activeModeID = mode.id
        }
        // Pre-populate the Anthropic Provider key so the AI call path is configured.
        settings.setAPIKey("test-key", for: .anthropic)
        self.settings = settings

        let audioRecorder = AudioRecorder()
        #if DEBUG
        let audioDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Helpers/
            .deletingLastPathComponent() // vcdr-macTests/
            .deletingLastPathComponent() // project root
            .appendingPathComponent("TestAudio")
        audioRecorder.testAudioFileURL = audioDir.appendingPathComponent(testAudioFileName)
        #endif
        self.audioRecorder = audioRecorder

        let historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdr-test-\(UUID().uuidString)")
        let history = FileHistoryStore(snapshot: FileHistoryStore.loadSnapshot(storageRoot: historyDir))
        self.history = history

        let overrides = SessionOverrides()
        let recordingIndicator = RecordingIndicatorPanel(
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        )
        let fakePanel = FakeCapturePanel()
        self.fakePanel = fakePanel

        let textProcessor = TextProcessor(
            aiPort: scriptedAI,
            history: history,
            settings: settings,
            overrides: overrides,
            styleProvider: { .casual }
        )
        self.textProcessor = textProcessor

        let hotkeyRegistry = FakeHotkeyRegistry()
        self.hotkeyRegistry = hotkeyRegistry
        let suspendableRegistry = SuspendableHotkeyRegistry(wrapping: hotkeyRegistry)
        self.suspendableRegistry = suspendableRegistry

        self.session = CaptureSession(
            settings: settings,
            history: history,
            deps: .init(
                transcription: {
                    settings.transcriptionSettings.defaultModel == mockProvider.model
                        ? mockProvider : alternateProvider
                },
                hotkeyRegistry: suspendableRegistry,
                audio: audioRecorder,
                media: MediaPlaybackController(),
                selectionCapturer: SelectionCapturer(),
                clipboardMonitor: ClipboardMonitor(),
                indicator: recordingIndicator,
                panel: fakePanel,
                textProcessor: textProcessor,
                substitutionStore: SubstitutionStoreProxy(),
                overrides: overrides,
                styleProvider: { .casual }
            )
        )
    }

    // MARK: - Wait helpers

    /// Polls session phase until the condition is true or the timeout expires.
    func waitForPhase(_ condition: @escaping (CaptureSession.Status.Phase) -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < Self.stateTimeout {
            if condition(session.status.phase) { return true }
            try? await Task.sleep(for: Self.statePollingInterval)
        }
        return false
    }

    /// Waits for a resting phase (idle, error, or awaitingPreview).
    func waitForRest() async -> Bool {
        await waitForPhase { phase in
            if case .idle = phase { return true }
            if case .error = phase { return true }
            if case .awaitingPreview = phase { return true }
            return false
        }
    }

    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}
