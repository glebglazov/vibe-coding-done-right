import Foundation
import AVFoundation
import OSLog

@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    /// Rolling buffer of recent audio level samples (0.0–1.0), one per meter tick.
    private(set) var audioLevels: [Float] = Array(repeating: 0, count: levelSampleCount)

    private var audioRecorder: AVAudioRecorder?
    /// nonisolated(unsafe) allows deinit cleanup. Safe because deinit runs
    /// only when no other references exist, so no concurrent access is possible.
    private nonisolated(unsafe) var levelTimer: Timer?
    private var recordingStartTime: ContinuousClock.Instant?

    // MARK: - Constants

    /// Number of audio level samples kept for the waveform display
    static let levelSampleCount = 20
    /// How fast the displayed level drops when audio quiets down (0 = instant, 1 = no decay)
    private static let levelDecayFactor: Float = 0.3
    /// Parakeet's native sample rate — all recordings use this to avoid resampling
    private static let sampleRate: Double = 16000
    /// Minimum frames Parakeet can process (1 second at 16kHz)
    private static let minimumFrameCount: AVAudioFrameCount = 16000
    /// Duration threshold below which silence padding is needed
    private static let minimumRecordingDuration: Duration = .seconds(1)
    /// Mono channel for voice recording
    private static let channelCount = 1
    /// 16-bit PCM depth for Parakeet compatibility
    private static let bitDepth = 16

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording() async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        // Configure iOS audio session for recording.
        // Uses .playAndRecord so UIBackgroundModes:audio keeps the session alive
        // when the app goes to background during the flash-and-bounce flow.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            Logger.recording.error("Failed to configure audio session: \(error)")
            return false
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("vcdr_recording_\(UUID().uuidString).wav")

        // Record at 16kHz mono — Parakeet's native format, no resampling needed
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: Self.bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFile, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()

            guard audioRecorder?.record() == true else {
                Logger.recording.error("Failed to start recording")
                return false
            }

            isRecording = true
            recordingStartTime = .now
            startLevelMonitoring()
            Logger.recording.info("Recording started: \(audioFile.lastPathComponent)")
            return true
        } catch {
            Logger.recording.error("Recording setup failed: \(error)")
            return false
        }
    }

    func stopRecording() -> URL? {
        guard let recorder = audioRecorder else { return nil }

        let url = recorder.url
        recorder.stop()
        stopLevelMonitoring()

        // Don't deactivate audio session — keep it alive for background recording.
        // The session persists when the app goes to background via UIBackgroundModes:audio.

        let wasShort = recordingStartTime.map {
            $0.duration(to: .now) < Self.minimumRecordingDuration
        } ?? false

        isRecording = false
        audioLevels = Array(repeating: 0, count: Self.levelSampleCount)
        audioRecorder = nil
        recordingStartTime = nil

        if wasShort { padToMinimumDuration(fileURL: url) }
        Logger.recording.info("Recording stopped: \(url.lastPathComponent)")
        return url
    }

    // MARK: - Silence Padding

    /// Pads a short recording with silence so Parakeet can process it.
    /// Parakeet requires at least 1 second of audio; quick utterances like
    /// "yes" or "no" may be shorter. Silence is zero-valued PCM samples.
    private func padToMinimumDuration(fileURL: URL) {
        do {
            let inputFile = try AVAudioFile(forReading: fileURL)
            let frameCount = AVAudioFrameCount(inputFile.length)

            guard frameCount < Self.minimumFrameCount else { return }

            let silenceFrames = Self.minimumFrameCount - frameCount
            let format = inputFile.processingFormat

            // Read original audio
            guard let originalBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            try inputFile.read(into: originalBuffer)

            // Create silence buffer (AVAudioPCMBuffer is zero-filled by default)
            guard let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: silenceFrames) else { return }
            silenceBuffer.frameLength = silenceFrames

            // Write original + silence to same URL
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: inputFile.fileFormat.settings)
            try outputFile.write(from: originalBuffer)
            try outputFile.write(from: silenceBuffer)

            Logger.recording.info("Padded short recording from \(frameCount) to \(Self.minimumFrameCount) frames")
        } catch {
            // Non-fatal — let Parakeet attempt transcription on the original file
            Logger.recording.warning("Failed to pad short recording: \(error)")
        }
    }

    // MARK: - Level Monitoring

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            let linear = max(0.0, (averagePower + 60) / 60)
            // Square root curve expands the speech range (~0.4–0.8 linear)
            // into a wider visual range, making the waveform more responsive
            let curved = sqrt(linear)
            // Fast attack, quick decay: jump to new level immediately when louder,
            // but decay exponentially when quieter so bars drop fast after speech
            let previous = self.audioLevels.last ?? 0
            let smoothed = curved >= previous ? curved : previous * Self.levelDecayFactor + curved * (1 - Self.levelDecayFactor)
            self.audioLevels.removeFirst()
            self.audioLevels.append(smoothed)
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    deinit {
        levelTimer?.invalidate()
    }
}
