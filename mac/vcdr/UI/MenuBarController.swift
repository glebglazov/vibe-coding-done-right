//
//  MenuBarController.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Combine

enum DestinationType {
    case clipboard
    case tmux
}

@MainActor
class MenuBarController: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isInitializing = true
    @Published var statusMessage = "Initializing Whisper..."
    @Published var lastTranscription = ""
    private var intendedDestination: DestinationType?

    let audioRecorder = AudioRecorder()
    private let whisperService = WhisperKitService.shared
    private let clipboardDestination = ClipboardDestination()
    private let tmuxDestination = TmuxDestination()
    private let hotkeyManager = GlobalHotkeyManager()
    private var permissionMonitorTimer: Timer?

    init() {
        print("📱 MenuBarController: Initializing...")
        print("🎯 Available destinations: Clipboard, Tmux")

        Task {
            await initializeWhisper()
            await requestMicrophonePermissionOnStartup()
        }
        setupGlobalHotkey()
        startPermissionMonitoring()
    }

    private func setupGlobalHotkey() {
        print("🎹 MenuBarController: Setting up global hotkey...")
        let success = hotkeyManager.registerHotkey { [weak self] in
            print("🔥 Recording hotkey triggered!")
            self?.toggleRecording()
        }
        if success {
            print("✅ MenuBarController: Global hotkey setup completed successfully")
        } else {
            print("❌ MenuBarController: Failed to register global hotkey - accessibility permissions may be needed")
        }
    }

    func updateGlobalShortcut() {
        let success = hotkeyManager.updateHotkey()
        if success {
            print("Global shortcut updated")
        } else {
            print("Failed to update global shortcut")
        }
    }

    func retryGlobalShortcut() {
        print("🔄 Manually retrying global shortcut registration...")
        setupGlobalHotkey()
    }

    private func startPermissionMonitoring() {
        // Only start monitoring if hotkey is not already registered
        guard !hotkeyManager.isHotkeyRegistered() else {
            print("👍 Global hotkey already registered, no monitoring needed")
            return
        }

        print("👁️ Starting accessibility permission monitoring...")

        // Check every 2 seconds for permission changes
        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            let hasPermissions = AXIsProcessTrusted()

            // Check if permissions state changed from denied to granted
            if hasPermissions && !(self?.hotkeyManager.isHotkeyRegistered() ?? false) {
                print("🎉 Accessibility permissions granted! Re-registering global hotkey...")
                self?.setupGlobalHotkey()

                // Stop monitoring once successful
                if self?.hotkeyManager.isHotkeyRegistered() ?? false {
                    print("✋ Stopping permission monitoring - hotkey successfully registered")
                    self?.permissionMonitorTimer?.invalidate()
                    self?.permissionMonitorTimer = nil
                }
            }
        }
    }

    private func initializeWhisper() async {
        do {
            await MainActor.run {
                statusMessage = "Downloading and initializing Whisper model..."
            }
            try await whisperService.initialize()
            await MainActor.run {
                isInitializing = false
                statusMessage = "Ready to record"
            }
        } catch {
            await MainActor.run {
                isInitializing = false
                statusMessage = "Failed to initialize Whisper"
            }
            print("WhisperKit initialization error: \(error)")
        }
    }

    private func requestMicrophonePermissionOnStartup() async {
        print("🎤 MenuBarController: Requesting microphone permission on startup...")
        let hasPermission = await audioRecorder.requestMicrophonePermission()

        if hasPermission {
            print("✅ MenuBarController: Microphone permission granted")
            await MainActor.run {
                if statusMessage == "Ready to record" {
                    // Keep the ready message if we're already ready
                } else if !isInitializing {
                    statusMessage = "Ready to record"
                }
            }
        } else {
            print("❌ MenuBarController: Microphone permission denied")
            await MainActor.run {
                statusMessage = "Microphone permission needed"
            }
        }
    }


    func stopAndSendToClipboard() {
        stopRecordingAndSendTo(.clipboard)
    }

    func stopAndSendToTmux() {
        stopRecordingAndSendTo(.tmux)
    }

    private var previousActiveApp: NSRunningApplication?

    private func stopRecordingAndSendTo(_ destination: DestinationType) {
        guard isRecording else { return }
        intendedDestination = destination

        // previousActiveApp was already stored when recording started

        // Stop recording and let the transcription flow handle sending to destination
        guard let audioURL = audioRecorder.stopRecording() else {
            Task {
                await MainActor.run {
                    isRecording = false
                    statusMessage = "Recording failed"
                }
            }
            return
        }

        Task {
            await MainActor.run {
                isRecording = false
                isProcessing = true
                statusMessage = "Transcribing..."
            }

            do {
                let transcription = try await whisperService.transcribe(audioFileURL: audioURL)
                await handleTranscriptionResult(transcription)

                // Clean up the audio file
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                await handleTranscriptionError(error)
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        _ = audioRecorder.stopRecording()

        Task {
            await MainActor.run {
                isRecording = false
                statusMessage = "Recording cancelled"
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.statusMessage = "Ready to record"
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task {
                await startRecording()
            }
        }
    }

    private func startRecording() async {
        // Store the currently active app BEFORE showing recording overlay
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        let success = await audioRecorder.startRecording()
        await MainActor.run {
            if success {
                isRecording = true
                statusMessage = "Recording... Tap to stop"
                print("✅ MenuBarController: Recording started, overlay should be visible")
            } else {
                statusMessage = "Failed to start recording"
            }
        }
    }

    private func stopRecording() {
        guard let audioURL = audioRecorder.stopRecording() else {
            Task {
                await MainActor.run {
                    statusMessage = "Recording failed"
                }
            }
            return
        }

        Task {
            await MainActor.run {
                isRecording = false
                isProcessing = true
                statusMessage = "Transcribing..."
            }

            do {
                let transcription = try await whisperService.transcribe(audioFileURL: audioURL)
                await handleTranscriptionResult(transcription)

                // Clean up the audio file
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                await handleTranscriptionError(error)
            }
        }
    }

    private func handleTranscriptionResult(_ transcription: String) async {
        lastTranscription = transcription

        if let destination = intendedDestination {
            // Direct send to intended destination
            let destinationService: TextDestination
            switch destination {
            case .clipboard:
                destinationService = clipboardDestination
            case .tmux:
                destinationService = tmuxDestination
            }

            await sendTranscriptionToDestination(transcription, destination: destinationService)
            intendedDestination = nil
        } else {
            // Manual stop - just finish processing without showing picker
            await MainActor.run {
                statusMessage = "Transcription complete"
                isProcessing = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusMessage = "Ready to record"
            }
        }
    }

    private func sendTranscriptionToDestination(_ transcription: String, destination: TextDestination) async {
        print("📤 Sending text to \(destination.name)...")

        await MainActor.run {
            statusMessage = "Sending to \(destination.name)..."
        }

        do {
            try await destination.send(text: transcription)
            print("✅ Successfully sent to \(destination.name)")

            await MainActor.run {
                statusMessage = "Sent to \(destination.name)!"
                isProcessing = false
            }

            // Restore focus to previously active app
            await restorePreviousAppFocus()

            // Reset status after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusMessage = "Ready to record"
            }
        } catch {
            print("❌ Failed to send to \(destination.name): \(error)")

            await MainActor.run {
                if let destError = error as? DestinationError {
                    statusMessage = destError.localizedDescription
                } else {
                    statusMessage = "Failed to send to \(destination.name)"
                }
                isProcessing = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.statusMessage = "Ready to record"
            }
        }
    }

    private func handleTranscriptionError(_ error: Error) async {
        print("Transcription error: \(error)")

        if let whisperKitError = error as? WhisperKitError {
            statusMessage = whisperKitError.localizedDescription
        } else {
            statusMessage = "Transcription failed"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.statusMessage = "Ready to record"
            self.isProcessing = false
        }
    }

    private func restorePreviousAppFocus() async {
        guard let previousApp = previousActiveApp else {
            print("❌ No previous app to restore focus to")
            return
        }

        print("🎯 Restoring focus to: \(previousApp.localizedName ?? "Unknown app")")

        await MainActor.run {
            let success = previousApp.activate(options: [.activateIgnoringOtherApps])
            print(success ? "✅ Focus restored successfully" : "❌ Failed to restore focus")
            previousActiveApp = nil // Clear after use
        }
    }
}
