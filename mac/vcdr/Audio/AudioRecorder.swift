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
        print("🎤 AudioRecorder: Starting recording process...")

        guard await requestMicrophonePermission() else {
            print("❌ AudioRecorder: Microphone permission denied - check Privacy & Security settings")
            return false
        }

        print("✅ AudioRecorder: Microphone permission granted")

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsPath.appendingPathComponent("recording.wav")

        print("📁 AudioRecorder: Recording to: \(audioFilename.path)")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        print("🎛️ AudioRecorder: Audio settings: \(settings)")

        do {
            print("🔧 AudioRecorder: Creating AVAudioRecorder...")
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            print("✅ AudioRecorder: AVAudioRecorder created successfully")

            print("▶️ AudioRecorder: Starting recording...")
            if audioRecorder?.record() == true {
                print("✅ AudioRecorder: Recording started successfully")
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordingTime = 0
                    self.startTimer()
                }
                return true
            } else {
                print("❌ AudioRecorder: Failed to start recording - record() returned false")
                print("   This could be due to:")
                print("   - Audio session conflicts with other apps")
                print("   - Hardware issues with microphone")
                print("   - Invalid audio settings")
                print("   - File system permissions for documents directory")
                return false
            }
        } catch {
            print("❌ AudioRecorder: Failed to create AVAudioRecorder: \(error)")
            print("   Error details: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("   Error domain: \(nsError.domain)")
                print("   Error code: \(nsError.code)")
                print("   User info: \(nsError.userInfo)")
            }
            return false
        }
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