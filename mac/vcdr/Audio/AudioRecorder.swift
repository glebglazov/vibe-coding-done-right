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
    private var recordingTimer: Timer?

    override init() {
        super.init()
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
            print("Microphone permission denied")
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

            if audioRecorder?.record() == true {
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingTime = 0
                    self.startTimer()
                }
                return true
            }
        } catch {
            print("Failed to start recording: \(error)")
        }

        return false
    }

    func stopRecording() -> URL? {
        audioRecorder?.stop()
        stopTimer()

        DispatchQueue.main.async {
            self.isRecording = false
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
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("Recording failed")
        }
    }
}