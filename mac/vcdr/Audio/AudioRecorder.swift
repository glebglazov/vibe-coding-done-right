//
//  AudioRecorder.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation
import AVFoundation
import Combine

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?

    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    @Published var audioLevel: Float = 0.0
    private var recordingTimer: Timer?
    private var levelTimer: Timer?

    override init() {
        super.init()
    }

    func hasMicrophonePermission() -> Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophonePermission() async -> Bool {
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
            return false
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("recording.wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true

            if audioRecorder?.record() == true {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingTime = 0
                    self.startTimer()
                    self.startLevelMonitoring()
                }
                return true
            } else {
                return false
            }
        } catch {
            return false
        }
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        stopTimer()
        stopLevelMonitoring()

        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }

        return audioRecorder?.url
    }

    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            DispatchQueue.main.async {
                self.recordingTime += 0.1
            }
        }
    }

    private func stopTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard let recorder = self.audioRecorder, recorder.isRecording else { return }

            recorder.updateMeters()
            let averagePower = recorder.averagePower(forChannel: 0)

            // Convert dB to 0-1 range (dB range is typically -160 to 0)
            let normalizedLevel = max(0.0, (averagePower + 60) / 60)

            DispatchQueue.main.async {
                self.audioLevel = normalizedLevel
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
        }
    }
}