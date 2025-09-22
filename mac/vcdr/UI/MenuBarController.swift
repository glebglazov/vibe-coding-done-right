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
    @Published var currentDestinationType: DestinationType = .clipboard

    private let audioRecorder = AudioRecorder()
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
        setupGlobalHotkeys()
        startPermissionMonitoring()
    }

    private func setupGlobalHotkeys() {
        print("🎹 MenuBarController: Setting up global hotkeys...")
        let success = hotkeyManager.registerHotkeys(
            clipboardCallback: { [weak self] in
                print("🔥 Clipboard hotkey triggered!")
                self?.handleShortcutPressed(destinationType: .clipboard)
            },
            tmuxCallback: { [weak self] in
                print("🔥 Tmux hotkey triggered!")
                self?.handleShortcutPressed(destinationType: .tmux)
            }
        )
        if success {
            print("✅ MenuBarController: Global hotkeys setup completed successfully")
        } else {
            print("❌ MenuBarController: Failed to register global hotkeys - accessibility permissions may be needed")
        }
    }

    var currentDestination: TextDestination {
        switch currentDestinationType {
        case .clipboard:
            print("🎯 Current destination: Clipboard")
            return clipboardDestination
        case .tmux:
            print("🎯 Current destination: Tmux")
            return tmuxDestination
        }
    }

    func updateGlobalShortcuts() {
        let success = hotkeyManager.updateHotkeys()
        if success {
            print("Global shortcuts updated")
        } else {
            print("Failed to update global shortcuts")
        }
    }

    func retryGlobalShortcuts() {
        print("🔄 Manually retrying global shortcuts registration...")
        setupGlobalHotkeys()
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
                print("🎉 Accessibility permissions granted! Re-registering global hotkeys...")
                self?.setupGlobalHotkeys()

                // Stop monitoring once successful
                if self?.hotkeyManager.isHotkeyRegistered() ?? false {
                    print("✋ Stopping permission monitoring - hotkeys successfully registered")
                    self?.permissionMonitorTimer?.invalidate()
                    self?.permissionMonitorTimer = nil
                }
            }
        }
    }

    private func initializeWhisper() async {
        do {
            statusMessage = "Downloading and initializing Whisper model..."
            try await whisperService.initialize()
            isInitializing = false
            statusMessage = "Ready to record"
        } catch {
            isInitializing = false
            statusMessage = "Failed to initialize Whisper"
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

    func handleShortcutPressed(destinationType: DestinationType) {
        if isRecording {
            // If recording, stop and set destination based on which shortcut was pressed
            print("🎯 Stopping recording with destination: \(destinationType)")
            currentDestinationType = destinationType
            stopRecording()
        } else {
            // If not recording, start recording (destination will be set when stopping)
            print("🎤 Starting recording (destination to be determined on stop)")
            Task {
                await startRecording()
            }
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
        let success = await audioRecorder.startRecording()
        if success {
            isRecording = true
            statusMessage = "Recording... Tap to stop"
        } else {
            statusMessage = "Failed to start recording"
        }
    }

    private func stopRecording() {
        guard let audioURL = audioRecorder.stopRecording() else {
            statusMessage = "Recording failed"
            return
        }

        isRecording = false
        isProcessing = true
        statusMessage = "Transcribing..."

        Task {
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
        let destination = currentDestination

        print("📝 Transcription completed: \"\(transcription)\"")
        print("🎯 Selected destination: \(destination.name) (\(currentDestinationType))")
        print("📤 Sending text to \(destination.name)...")

        statusMessage = "Sending to \(destination.name)..."

        do {
            try await destination.send(text: transcription)
            print("✅ Successfully sent to \(destination.name)")
            statusMessage = "Sent to \(destination.name)!"

            // Reset status after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusMessage = "Ready to record"
                self.isProcessing = false
            }
        } catch {
            print("❌ Failed to send to \(destination.name): \(error)")
            if let destError = error as? DestinationError {
                print("   Destination error details: \(destError.localizedDescription)")
                statusMessage = destError.localizedDescription
            } else {
                print("   Generic error: \(error.localizedDescription)")
                statusMessage = "Failed to send to \(destination.name)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.statusMessage = "Ready to record"
                self.isProcessing = false
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
}