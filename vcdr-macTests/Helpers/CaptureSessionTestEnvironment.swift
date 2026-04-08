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
    let history: TranscriptionHistory
    let fakePanel: FakeCapturePanel
    let scriptedAI: ScriptedAIProcessing
    let mockProvider: MockTranscriptionProvider
    let audioRecorder: AudioRecorder

    private let userDefaultsSuiteName: String

    /// Creates a test environment wired with a copy-to-clipboard default destination so
    /// the default "paste" code path (which needs CGEvent accessibility) never runs.
    init(
        mockProvider: MockTranscriptionProvider = MockTranscriptionProvider(),
        testAudioFileName: String = "short.wav",
        aiResults: [Result<String, Error>] = [],
        modePreview: Bool = false,
        modeProcessing: ProcessingType = .none
    ) {
        self.mockProvider = mockProvider
        self.scriptedAI = ScriptedAIProcessing(results: aiResults)

        let suiteName = "vcdr.test.\(UUID().uuidString)"
        self.userDefaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(userDefaults: defaults)
        // Disable media pause to avoid hanging on MediaRemoteClient resolution in tests.
        settings.audioSettings = AudioSettings(preferredInputDeviceID: nil, pauseMediaDuringRecording: false)
        // Disable terminator so test assertions can match exact transcription output.
        settings.terminatorTemplateEnabled = false
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
        }
        // Pre-populate Anthropic API key so AIClient fallback path isn't hit.
        if let idx = settings.variables.firstIndex(where: { $0.name == "ANTHROPIC_API_KEY" }) {
            settings.variables[idx].value = "test-key"
        }
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

        let history = TranscriptionHistory()
        self.history = history

        let overrides = SessionOverrides()
        let recordingIndicator = RecordingIndicatorPanel(
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        )
        let fakePanel = FakeCapturePanel()
        self.fakePanel = fakePanel

        self.session = CaptureSession(
            settings: settings,
            history: history,
            deps: .init(
                transcription: mockProvider,
                audio: audioRecorder,
                media: MediaPlaybackController(),
                selectionCapturer: SelectionCapturer(),
                clipboardMonitor: ClipboardMonitor(),
                indicator: recordingIndicator,
                panel: fakePanel,
                ai: scriptedAI,
                overrides: overrides
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
