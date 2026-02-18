import Foundation
import AVFoundation
import OSLog

@Observable
final class AudioRecorder: NSObject {
    private(set) var isRecording = false
    private(set) var audioLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?

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
            AVSampleRateKey: 16000,
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

        isRecording = false
        audioLevel = 0.0
        audioRecorder = nil

        Logger.recording.info("Recording stopped: \(url.lastPathComponent)")
        return url
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
