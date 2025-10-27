//
//  MenuBarController.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import SwiftUI
import Combine

enum DestinationType {
    case paste
    case copy
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
    private var capturedSelectedText: String?

    let audioRecorder = AudioRecorder()
    private let whisperService = WhisperKitService.shared
    private let modeManager = ModeManager.shared
    private let pasteDestination = PasteDestination()
    private let copyDestination = CopyDestination()
    private let tmuxDestination = TmuxDestination()
    private let hotkeyManager = GlobalHotkeyManager()
    private var permissionMonitorTimer: Timer?

    init() {
        print("📱 MenuBarController: Initializing...")
        print("🎯 Available destinations: Clipboard, Tmux")

        // Sync mode manager with app settings
        let settings = AppSettings.shared
        modeManager.isEnabled = settings.isModeEnabled
        modeManager.setMode(named: settings.activeModeName)

        Task {
            await initializeWhisper()
            await requestMicrophonePermissionOnStartup()
            await MainActor.run {
                setupGlobalHotkey()
                startPermissionMonitoring()
            }
        }
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
            guard let self = self else { return }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let hasPermissions = AXIsProcessTrusted()

                // Check if permissions state changed from denied to granted
                if hasPermissions && !self.hotkeyManager.isHotkeyRegistered() {
                    print("🎉 Accessibility permissions granted! Re-registering global hotkey...")
                    self.setupGlobalHotkey()

                    // Stop monitoring once successful
                    if self.hotkeyManager.isHotkeyRegistered() {
                        print("✋ Stopping permission monitoring - hotkey successfully registered")
                        self.permissionMonitorTimer?.invalidate()
                        self.permissionMonitorTimer = nil
                    }
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


    func stopAndPaste() {
        stopRecordingAndSendTo(.paste)
    }

    func stopAndCopyToClipboard() {
        stopRecordingAndSendTo(.copy)
    }

    func stopAndSendToTmux() {
        stopRecordingAndSendTo(.tmux)
    }

    func switchToDisabledMode() {
        modeManager.setMode(named: "Disabled")
        let settings = AppSettings.shared
        settings.activeModeName = "Disabled"
        settings.saveSettings()
        print("🔄 Switched to Disabled mode")
    }

    func switchToAssistantMode() {
        modeManager.setMode(named: "Assistant")
        let settings = AppSettings.shared
        settings.activeModeName = "Assistant"
        settings.saveSettings()
        print("🔄 Switched to Assistant mode")
    }

    private(set) var previousActiveApp: NSRunningApplication?

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

        // Clear captured text on cancel
        capturedSelectedText = nil

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

        // Capture any selected text before showing recording overlay
        capturedSelectedText = await captureSelectedText()
        if let captured = capturedSelectedText {
            print("📋 Captured selected text: \(captured.prefix(50))...")
        }

        let success = await audioRecorder.startRecording()
        await MainActor.run {
            if success {
                isRecording = true
                statusMessage = "Recording... Tap to stop"
                print("✅ MenuBarController: Recording started, overlay should be visible")

                // Position recording window immediately since we don't need window size for top-left positioning
                positionRecordingWindow()
            } else {
                statusMessage = "Failed to start recording"
            }
        }
    }

    private func captureSelectedText() async -> String? {
        // Get current clipboard content to restore later
        let pasteboard = NSPasteboard.general
        let savedChangeCount = pasteboard.changeCount
        let savedContent = pasteboard.string(forType: .string)

        print("📋 === Clipboard State ===")
        print("Current clipboard content: \(savedContent ?? "[empty]")")
        print("Change count: \(savedChangeCount)")
        print("=========================")

        // Give a tiny delay to ensure app is focused
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Simulate Cmd+C to copy selected text
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down for Cmd+C
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C key
        keyDownEvent?.flags = .maskCommand
        keyDownEvent?.post(tap: .cghidEventTap)

        // Key up for Cmd+C
        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyUpEvent?.flags = .maskCommand
        keyUpEvent?.post(tap: .cghidEventTap)

        // Wait a bit for clipboard to update
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Check if clipboard changed (meaning text was selected)
        let newChangeCount = pasteboard.changeCount
        let capturedText: String?

        print("📋 === After Cmd+C ===")
        print("New change count: \(newChangeCount)")

        if newChangeCount != savedChangeCount {
            // Clipboard changed, get the new content
            capturedText = pasteboard.string(forType: .string)
            print("✅ Captured selected text: \(capturedText ?? "[empty]")")

            // Restore original clipboard content
            pasteboard.clearContents()
            if let savedContent = savedContent {
                pasteboard.setString(savedContent, forType: .string)
            }
            print("♻️ Restored original clipboard")
        } else {
            // No text was selected
            capturedText = nil
            print("ℹ️ No text was selected (clipboard unchanged)")
        }
        print("=====================")

        return capturedText
    }

    private func positionRecordingWindow() {
        // Find the recording window
        guard let recordingWindow = NSApp.windows.first(where: { $0.title == "Recording" }) else {
            print("❌ MenuBarController: Could not find recording window to position")
            return
        }

        // Try to get the screen where the active application is located
        var targetScreen: NSScreen?

        // Method 1: Get screen from previously active application's main window
        if let activeApp = previousActiveApp {
            // Get the frontmost window of the active app using Core Graphics
            if let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
                for windowInfo in windowList {
                    if let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                       windowOwnerPID == activeApp.processIdentifier,
                       let windowLayer = windowInfo[kCGWindowLayer as String] as? Int,
                       windowLayer == 0, // Normal window layer
                       let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                       let x = boundsDict["X"] as? CGFloat,
                       let y = boundsDict["Y"] as? CGFloat,
                       let width = boundsDict["Width"] as? CGFloat,
                       let height = boundsDict["Height"] as? CGFloat {

                        let windowFrame = CGRect(x: x, y: y, width: width, height: height)

                        // Find which screen contains this window
                        targetScreen = NSScreen.screens.first { screen in
                            screen.frame.intersects(windowFrame)
                        }

                        if targetScreen != nil {
                            print("🎯 MenuBarController: Found active app window on screen")
                            break
                        }
                    }
                }
            }
        }

        // Method 2: Fall back to screen with cursor
        if targetScreen == nil {
            let mouseLocation = NSEvent.mouseLocation
            targetScreen = NSScreen.screens.first { screen in
                screen.frame.contains(mouseLocation)
            }
            print("🖱️ MenuBarController: Using cursor position as fallback")
        }

        // Method 3: Fall back to main screen
        if targetScreen == nil {
            targetScreen = NSScreen.main
            print("🖥️ MenuBarController: Using main screen as final fallback")
        }

        guard let screen = targetScreen else { return }

        // Position the recording window in top-left corner of the target screen
        let screenFrame = screen.frame
        let margin: CGFloat = 20 // Distance from screen edge

        print("📍 MenuBarController: Positioning recording window on screen: \(screen.localizedName)")

        // Position in top-left corner with margin
        let windowX = screenFrame.minX + margin
        let windowY = screenFrame.maxY - margin // maxY is top, position slightly below top edge

        // Set just the origin since we don't need to know window size for top-left positioning
        recordingWindow.setFrameOrigin(NSPoint(x: windowX, y: windowY))

        print("✅ Window positioned at: \(recordingWindow.frame)")
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

        // Prepend captured selected text if available
        var textToProcess = transcription
        if let captured = capturedSelectedText, !captured.isEmpty {
            textToProcess = """
            \(transcription)

            \(captured)
            """
            print("📝 Prepended selected text to transcription")
        }

        // Clear captured text after use
        capturedSelectedText = nil

        // Restore focus to previous app BEFORE LLM processing
        // This allows user to continue working while AI processes
        await restorePreviousAppFocus()

        // Process through mode system
        let processedText: String
        do {
            await MainActor.run {
                if modeManager.isEnabled && !(modeManager.activeMode is DisabledMode) {
                    statusMessage = "Processing with \(modeManager.activeMode?.name ?? "mode")..."
                }
            }

            processedText = try await modeManager.processText(textToProcess)
        } catch {
            print("❌ Mode processing error: \(error)")
            await MainActor.run {
                if let localizedError = error as? LocalizedError,
                   let errorDescription = localizedError.errorDescription {
                    statusMessage = errorDescription
                } else {
                    statusMessage = "Mode processing failed: \(error.localizedDescription)"
                }
            }
            processedText = transcription // Fallback to raw transcription on error

            // Show error for longer so user can read it
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        if let destination = intendedDestination {
            // Direct send to intended destination
            let destinationService: TextDestination
            switch destination {
            case .paste:
                destinationService = pasteDestination
            case .copy:
                destinationService = copyDestination
            case .tmux:
                destinationService = tmuxDestination
            }

            await sendTranscriptionToDestination(processedText, destination: destinationService)
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
            // Focus already restored early, so no need for onPrepareSend callback
            try await destination.send(text: transcription, onPrepareSend: nil)
            print("✅ Successfully sent to \(destination.name)")

            await MainActor.run {
                statusMessage = "Sent to \(destination.name)!"
                isProcessing = false
            }

            // Focus restoration already happened in onPrepareSend callback

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
            let success = previousApp.activate()
            print(success ? "✅ Focus restored successfully" : "❌ Failed to restore focus")
            previousActiveApp = nil // Clear after use
        }
    }
}
