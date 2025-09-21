//
//  MenuBarController.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Combine

@MainActor
class MenuBarController: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isInitializing = true
    @Published var statusMessage = "Initializing Whisper..."
    @Published var lastTranscription = ""
    @Published var selectedDestinationIndex = 0 {
        didSet {
            UserDefaults.standard.set(selectedDestinationIndex, forKey: "selectedDestinationIndex")
            print("🎯 Destination changed to: \(destinations[selectedDestinationIndex].name) (index: \(selectedDestinationIndex))")
        }
    }

    private let audioRecorder = AudioRecorder()
    private let whisperService = WhisperKitService.shared
    private let destinations: [TextDestination] = [
        ClipboardDestination(),
        TmuxDestination()
    ]
    private let hotkeyManager = GlobalHotkeyManager()
    private var permissionMonitorTimer: Timer?

    init() {
        print("📱 MenuBarController: Initializing...")
        print("🎯 Available destinations: \(destinations.map { $0.name })")

        // Load saved destination index
        let savedIndex = UserDefaults.standard.integer(forKey: "selectedDestinationIndex")
        if savedIndex < destinations.count {
            selectedDestinationIndex = savedIndex
        }

        print("🎯 Selected destination: \(destinations[selectedDestinationIndex].name) (index: \(selectedDestinationIndex))")

        Task {
            await initializeWhisper()
        }
        setupGlobalHotkey()
        startPermissionMonitoring()
    }

    private func setupGlobalHotkey() {
        print("🎹 MenuBarController: Setting up global hotkey...")
        let success = hotkeyManager.registerHotkey { [weak self] in
            print("🔥 Global hotkey triggered! Toggling recording...")
            self?.toggleRecording()
        }
        if success {
            print("✅ MenuBarController: Global hotkey setup completed successfully")
        } else {
            print("❌ MenuBarController: Failed to register global hotkey - accessibility permissions may be needed")
        }
    }

    var availableDestinations: [String] {
        return destinations.map { $0.name }
    }

    var currentDestination: TextDestination {
        let destination = destinations[selectedDestinationIndex]
        print("🎯 Current destination: \(destination.name) (index: \(selectedDestinationIndex))")
        return destination
    }

    func updateGlobalShortcut() {
        let success = hotkeyManager.updateHotkey()
        if success {
            print("Global shortcut updated to: \(AppSettings.shared.shortcutDisplayString)")
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
        print("🎯 Selected destination: \(destination.name) (index: \(selectedDestinationIndex))")
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