import Foundation
import Testing
@testable import vcdr

/// Constructs a fully-wired RecordingCoordinator with mock transcription and
/// test audio, capturing all callback results for assertion.
@MainActor
struct E2ETestEnvironment {

    // MARK: - Constants

    private static let statePollingInterval: Duration = .milliseconds(50)
    private static let stateTimeout: Duration = .seconds(30)

    let coordinator: RecordingCoordinator
    let mockProvider: MockTranscriptionProvider
    let audioRecorder: AudioRecorder
    let settings: AppSettings

    /// Results captured from coordinator callbacks.
    let results: CallbackResults

    private let userDefaultsSuiteName: String

    /// Mutable container for callback captures, shared via reference.
    /// Also acts as the RecordingCoordinatorDelegate for test assertions.
    @MainActor
    final class CallbackResults: RecordingCoordinatorDelegate {
        var completed: [RecordingResult] = []
        var failedMessages: [String] = []
        var transcriptionFailedCount = 0
        var cancelledCount = 0

        func recordingCoordinatorWillStartRecording() {}
        func recordingCoordinatorIsPanelVisible() -> Bool { false }
        func recordingCoordinatorDidStartRecording(isFollowUp: Bool) {}
        func recordingCoordinatorDidStartTranscribing() {}
        func recordingCoordinatorDidCompleteRecording(result: RecordingResult) {
            completed.append(result)
        }
        func recordingCoordinatorDidFailTranscription(isFollowUp: Bool) {
            transcriptionFailedCount += 1
        }
        func recordingCoordinatorDidCancelRecording(wasFollowUp: Bool, wasFreshPill: Bool) {
            cancelledCount += 1
        }
        func recordingCoordinatorDidFailRecording(message: String) {
            failedMessages.append(message)
        }
        func recordingCoordinatorDidCaptureSelection() {}
        func recordingCoordinatorDidCaptureClipboard() {}
    }

    init(
        mockProvider: MockTranscriptionProvider = MockTranscriptionProvider(),
        testAudioFileName: String = "short.wav"
    ) {
        self.mockProvider = mockProvider

        let suiteName = "vcdr.test.\(UUID().uuidString)"
        self.userDefaultsSuiteName = suiteName
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = AppSettings(userDefaults: defaults)
        // Disable media pause to avoid hanging on MediaRemoteClient resolution in tests
        settings.audioSettings = AudioSettings(preferredInputDeviceID: nil, pauseMediaDuringRecording: false)
        // Disable terminator so test assertions can match exact transcription output
        settings.terminatorTemplateEnabled = false
        self.settings = settings

        let audioRecorder = AudioRecorder()
        #if DEBUG
        let audioDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Helpers/
            .deletingLastPathComponent() // vcdrTests/
            .deletingLastPathComponent() // project root
            .appendingPathComponent("TestAudio")
        audioRecorder.testAudioFileURL = audioDir.appendingPathComponent(testAudioFileName)
        #endif
        self.audioRecorder = audioRecorder

        let overrides = ConversationOverrides()
        let recordingIndicator = RecordingIndicatorPanel(
            settings: settings,
            overrides: overrides,
            audioRecorder: audioRecorder
        )
        let selectionCapturer = SelectionCapturer()
        let clipboardMonitor = ClipboardMonitor()

        self.coordinator = RecordingCoordinator(
            settings: settings,
            transcriptionProvider: mockProvider,
            audioRecorder: audioRecorder,
            mediaPlaybackController: MediaPlaybackController(),
            recordingIndicator: recordingIndicator,
            selectionCapturer: selectionCapturer,
            clipboardMonitor: clipboardMonitor,
            overrides: overrides
        )

        let results = CallbackResults()
        self.results = results
        coordinator.delegate = results
    }

    // MARK: - State Helpers

    /// Polls coordinator state until `condition` is true or timeout expires.
    func waitForState(_ condition: (RecordingCoordinator.State) -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while start.duration(to: .now) < Self.stateTimeout {
            if condition(coordinator.state) { return true }
            try? await Task.sleep(for: Self.statePollingInterval)
        }
        return false
    }

    /// Waits for coordinator to reach `.idle` or `.error`.
    func waitForIdle() async -> Bool {
        await waitForState { state in
            if case .idle = state { return true }
            if case .error = state { return true }
            return false
        }
    }

    /// Removes the test UserDefaults suite to avoid leaking state.
    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}
