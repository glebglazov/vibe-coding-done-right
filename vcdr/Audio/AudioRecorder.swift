import Foundation
import AVFoundation
import OSLog

@Observable
final class AudioRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingStartTime: ContinuousClock.Instant?

    // MARK: - Constants

    /// Parakeet's native sample rate — all recordings use this to avoid resampling
    private static let sampleRate: Double = 16000
    /// Minimum frames Parakeet can process (1 second at 16kHz)
    private static let minimumFrameCount: AVAudioFrameCount = 16000
    /// Duration threshold below which silence padding is needed
    private static let minimumRecordingDuration: Duration = .seconds(1)

    nonisolated func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                continuation.resume(returning: true)
            case .denied, .restricted:
                continuation.resume(returning: false)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    func startRecording() async -> Bool {
        guard await requestMicrophonePermission() else {
            Logger.recording.warning("Microphone permission denied")
            return false
        }

        let tempDir = FileManager.default.temporaryDirectory
        let audioFile = tempDir.appendingPathComponent("vcdr_recording_\(UUID().uuidString).wav")

        // Record at 16kHz mono — Parakeet's native format, no resampling needed
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
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

        let wasShort = recordingStartTime.map { $0.duration(to: .now) < Self.minimumRecordingDuration } ?? false

        isRecording = false
        audioLevel = 0.0
        audioRecorder = nil
        recordingStartTime = nil

        if wasShort {
            padToMinimumDuration(fileURL: url)
        }
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

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)
            self.audioLevel = max(0.0, (averagePower + 60) / 60)
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
