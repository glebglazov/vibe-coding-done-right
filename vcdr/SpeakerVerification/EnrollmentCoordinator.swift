import Foundation
import OSLog

/// Manages the voice enrollment flow: records multiple audio samples,
/// extracts voice features, and creates a voice profile.
@Observable
@MainActor
final class EnrollmentCoordinator {

    enum Phase: Equatable {
        case idle
        case recording(sample: Int)
        case processing
    }

    // MARK: - Constants

    static let enrollmentDuration: Duration = .seconds(3)
    static let sampleCount = 3
    private static let progressTimerInterval: TimeInterval = 0.05
    /// Brief pause between consecutive enrollment samples
    private static let interSampleDelay: Duration = .milliseconds(500)

    // MARK: - Observable State

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var hasProfile: Bool = false
    private(set) var errorMessage: String?

    // MARK: - Dependencies

    private let speakerVerifier: MFCCSpeakerVerifier
    private let audioRecorder: AudioRecorder
    private let settings: AppSettings

    @ObservationIgnored private var sampleURLs: [URL] = []
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?

    init(speakerVerifier: MFCCSpeakerVerifier, audioRecorder: AudioRecorder, settings: AppSettings) {
        self.speakerVerifier = speakerVerifier
        self.audioRecorder = audioRecorder
        self.settings = settings
    }

    func refreshProfileState() async {
        hasProfile = await speakerVerifier.hasEnrolledProfile
    }

    // MARK: - Enrollment

    func startEnrollment() {
        errorMessage = nil
        sampleURLs = []
        enrollmentTask = Task { @MainActor in
            await recordAllSamples()
        }
    }

    func cancelEnrollment() {
        enrollmentTask?.cancel()
        enrollmentTask = nil
        stopTimerAndRecorder()
        cleanUpSampleFiles()
        phase = .idle
    }

    func deleteProfile() {
        Task {
            await speakerVerifier.deleteProfile()
            hasProfile = false
            settings.voiceLockEnabled = false
        }
    }

    /// Must be called when the UI disappears to clean up timers and active recordings.
    func tearDown() {
        cancelEnrollment()
    }

    // MARK: - Private

    private func recordAllSamples() async {
        for sampleNumber in 1...Self.sampleCount {
            guard !Task.isCancelled else { return }

            phase = .recording(sample: sampleNumber)
            progress = 0

            let started = await audioRecorder.startRecording(deviceUID: settings.audioSettings.preferredInputDeviceID)
            guard started else {
                errorMessage = "Failed to start recording"
                phase = .idle
                return
            }

            startProgressTimer()
            try? await Task.sleep(for: Self.enrollmentDuration)
            stopTimer()
            progress = 1.0

            guard !Task.isCancelled else {
                _ = audioRecorder.stopRecording()
                return
            }

            guard let audioURL = audioRecorder.stopRecording() else {
                errorMessage = "No audio recorded"
                phase = .idle
                return
            }

            sampleURLs.append(audioURL)

            if sampleNumber < Self.sampleCount {
                try? await Task.sleep(for: Self.interSampleDelay)
            }
        }

        await finishEnrollment()
    }

    private func finishEnrollment() async {
        phase = .processing

        do {
            try await speakerVerifier.enroll(audioURLs: sampleURLs)
            hasProfile = true
            phase = .idle
            Logger.voiceLock.info("Voice enrollment completed successfully")
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            Logger.voiceLock.error("Voice enrollment failed: \(error)")
        }

        cleanUpSampleFiles()
    }

    private func startProgressTimer() {
        let startTime = ContinuousClock.now
        progressTimer = Timer.scheduledTimer(withTimeInterval: Self.progressTimerInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = startTime.duration(to: .now)
                let fraction = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let total = Double(Self.enrollmentDuration.components.seconds) + Double(Self.enrollmentDuration.components.attoseconds) / 1e18
                self.progress = min(fraction / total, 1.0)
            }
        }
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func stopTimerAndRecorder() {
        stopTimer()
        if audioRecorder.isRecording {
            _ = audioRecorder.stopRecording()
        }
    }

    private func cleanUpSampleFiles() {
        for url in sampleURLs {
            try? FileManager.default.removeItem(at: url)
        }
        sampleURLs = []
    }

    deinit {
        progressTimer?.invalidate()
    }
}
