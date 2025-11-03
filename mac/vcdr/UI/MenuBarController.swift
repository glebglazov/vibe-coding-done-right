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
    case preview
}

@MainActor
class MenuBarController: ObservableObject {
    @Published var isCapturing = false
    @Published var showResultsOverlay = false
    @Published var showKeyboardInputOverlay = false
    @Published var showPreviewWindow = false
    @Published var previewText = ""
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var isInitializing = true
    @Published var statusMessage = "Initializing Whisper..."
    @Published var lastTranscription = ""
    @Published var captureActions: [CaptureAction] = []
    @Published var keyboardInputJustAdded = false

    /// Combined text from all capture actions
    var capturedText: String {
        captureActions.map { $0.text }.joined(separator: "\n\n")
    }

    let audioRecorder = AudioRecorder()
    private let transcriptionProvider: any TranscriptionProvider = WhisperKitService.shared
    private let modeManager = ModeManager.shared
    private let captureHistory = CaptureHistory.shared
    private let pasteDestination = PasteDestination()
    private let copyDestination = CopyDestination()
    private let tmuxDestination = TmuxDestination()
    private let previewDestination = PreviewDestination()
    private let hotkeyManager = GlobalHotkeyManager()
    private var permissionMonitorTimer: Timer?

    // HUD notification manager (injected from app)
    weak var hudManager: HUDNotificationManager?

    // Callback to open windows (injected from view)
    var openWindowCallback: ((String) -> Void)?

    // Dynamic menu bar icon based on state
    var menuBarIcon: String {
        if isRecording {
            return "record.circle.fill"
        } else if isProcessing {
            return "waveform.circle"
        } else {
            return "mic.fill"
        }
    }

    init() {
        print("📱 MenuBarController: Initializing...")
        print("🎯 Available destinations: Clipboard, Tmux, Preview")

        // Sync mode manager with app settings
        let settings = AppSettings.shared
        modeManager.setMode(named: settings.activeModeName)

        // Setup preview destination callback
        previewDestination.onShowPreview = { [weak self] text in
            self?.previewText = text
            self?.showPreviewWindow = true
            self?.openWindowCallback?("preview-window")
        }

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
        print("🎹 MenuBarController: Setting up global hotkeys...")

        let settings = AppSettings.shared
        var hotkeys: [HotkeyRegistration] = []

        // 1. Capturing/toggle overlay shortcut
        if settings.isCapturingShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Toggle Capture",
                keyCode: settings.capturingShortcutKeyCode,
                modifiers: settings.capturingShortcutModifiers,
                callback: { [weak self] in
                    print("🔥 Capture hotkey triggered!")
                    self?.toggleCapture()
                }
            ))
        }

        // 2. Toggle recording in capture shortcut
        if settings.isToggleRecordingShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Toggle Recording",
                keyCode: settings.toggleRecordingShortcutKeyCode,
                modifiers: settings.toggleRecordingShortcutModifiers,
                callback: { [weak self] in
                    print("🎙️ Toggle recording hotkey triggered!")
                    self?.handleToggleRecordingShortcut()
                }
            ))
        }

        // 3. Add clipboard to capture shortcut
        if settings.isAddClipboardShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Add Clipboard",
                keyCode: settings.addClipboardShortcutKeyCode,
                modifiers: settings.addClipboardShortcutModifiers,
                callback: { [weak self] in
                    print("📋 Add clipboard hotkey triggered!")
                    self?.copySelectionAndAddToCapture()
                }
            ))
        }

        // 4. Preview capture shortcut
        if settings.isPreviewShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Preview Capture",
                keyCode: settings.previewShortcutKeyCode,
                modifiers: settings.previewShortcutModifiers,
                callback: { [weak self] in
                    print("👁️ Preview hotkey triggered!")
                    self?.handlePreviewShortcut()
                }
            ))
        }

        // 5. Add keyboard input to capture shortcut
        if settings.isAddKeyboardInputShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Add Keyboard Input",
                keyCode: settings.addKeyboardInputShortcutKeyCode,
                modifiers: settings.addKeyboardInputShortcutModifiers,
                callback: { [weak self] in
                    print("⌨️ Add keyboard input hotkey triggered!")
                    self?.handleAddKeyboardInputShortcut()
                }
            ))
        }

        let success = hotkeyManager.registerHotkeys(hotkeys: hotkeys)
        if success {
            print("✅ MenuBarController: Global hotkeys setup completed successfully")
        } else {
            print("❌ MenuBarController: Failed to register global hotkeys - accessibility permissions may be needed")
        }
    }

    func updateGlobalShortcut() {
        let settings = AppSettings.shared
        var hotkeys: [HotkeyRegistration] = []

        if settings.isCapturingShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Toggle Capture",
                keyCode: settings.capturingShortcutKeyCode,
                modifiers: settings.capturingShortcutModifiers,
                callback: { [weak self] in
                    self?.toggleCapture()
                }
            ))
        }

        if settings.isToggleRecordingShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Toggle Recording",
                keyCode: settings.toggleRecordingShortcutKeyCode,
                modifiers: settings.toggleRecordingShortcutModifiers,
                callback: { [weak self] in
                    self?.handleToggleRecordingShortcut()
                }
            ))
        }

        if settings.isAddClipboardShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Add Clipboard",
                keyCode: settings.addClipboardShortcutKeyCode,
                modifiers: settings.addClipboardShortcutModifiers,
                callback: { [weak self] in
                    self?.copySelectionAndAddToCapture()
                }
            ))
        }

        if settings.isPreviewShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Preview Capture",
                keyCode: settings.previewShortcutKeyCode,
                modifiers: settings.previewShortcutModifiers,
                callback: { [weak self] in
                    self?.handlePreviewShortcut()
                }
            ))
        }

        if settings.isAddKeyboardInputShortcutSet {
            hotkeys.append(HotkeyRegistration(
                name: "Add Keyboard Input",
                keyCode: settings.addKeyboardInputShortcutKeyCode,
                modifiers: settings.addKeyboardInputShortcutModifiers,
                callback: { [weak self] in
                    self?.handleAddKeyboardInputShortcut()
                }
            ))
        }

        let success = hotkeyManager.updateHotkeys(hotkeys: hotkeys)
        if success {
            print("Global shortcuts updated")
        } else {
            print("Failed to update global shortcuts")
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
                statusMessage = "Downloading and initializing transcription model..."
            }
            try await transcriptionProvider.initialize()
            await MainActor.run {
                isInitializing = false
                statusMessage = "Ready to capture"
            }
        } catch {
            await MainActor.run {
                isInitializing = false
                statusMessage = "Failed to initialize transcription"
            }
            print("Transcription provider initialization error: \(error)")
        }
    }

    private func requestMicrophonePermissionOnStartup() async {
        print("🎤 MenuBarController: Requesting microphone permission on startup...")
        let hasPermission = await audioRecorder.requestMicrophonePermission()

        if hasPermission {
            print("✅ MenuBarController: Microphone permission granted")
            await MainActor.run {
                if statusMessage == "Ready to capture" || statusMessage == "Ready to record" {
                    // Keep the ready message if we're already ready
                } else if !isInitializing {
                    statusMessage = "Ready to capture"
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

    func stopAndPreview() {
        stopRecordingAndSendTo(.preview)
    }

    func switchToDisabledMode() {
        modeManager.setMode(named: "Disabled")
        let settings = AppSettings.shared
        settings.activeModeName = "Disabled"
        settings.saveSettings()
        print("🔄 Switched to Disabled mode")

        // Show HUD notification
        // hudManager?.showModeChanged(to: "Disabled Mode", isRecording: isRecording)
    }

    func switchToAssistantMode() {
        modeManager.setMode(named: "Assistant")
        let settings = AppSettings.shared
        settings.activeModeName = "Assistant"
        settings.saveSettings()
        print("🔄 Switched to Assistant mode")

        // Show HUD notification
        // hudManager?.showModeChanged(to: "Assistant Mode", isRecording: isRecording)
    }

    func cycleCustomModes() {
        modeManager.cycleCustomMode()
        // Save the active mode name to settings
        if let activeMode = modeManager.activeMode {
            let settings = AppSettings.shared
            settings.activeModeName = activeMode.name
            settings.saveSettings()

            // Show HUD notification
            // hudManager?.showModeChanged(to: activeMode.name, isRecording: isRecording)
        }
    }

    private(set) var previousActiveApp: NSRunningApplication?

    private func stopRecordingAndSendTo(_ destination: DestinationType) {
        finishAndSendTo(destination)
    }

    private func finishAndSendTo(_ destination: DestinationType) {
        // If still recording, stop it first
        if isRecording {
            stopRecordingInOverlay()
        }

        // Wait a bit if processing
        if isProcessing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.finishAndSendTo(destination)
            }
            return
        }

        // Close results overlay immediately
        showResultsOverlay = false

        // Use combined text from all capture actions
        let textToProcess = capturedText

        Task {
            await MainActor.run {
                isProcessing = true
                statusMessage = "Processing..."

                // Show HUD notification for processing start
                // let modeName = modeManager.activeMode?.name ?? "Disabled"
                // hudManager?.showProcessingStarted(mode: modeName)
            }

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
                processedText = textToProcess // Fallback to raw text on error

                // Show error for longer so user can read it
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }

            // Send to destination
            let destinationService: TextDestination
            switch destination {
            case .paste:
                destinationService = pasteDestination
            case .copy:
                destinationService = copyDestination
            case .tmux:
                destinationService = tmuxDestination
            case .preview:
                destinationService = previewDestination
            }

            // Restore focus to previous app before sending (if destination requires it)
            if destinationService.shouldRestoreFocus {
                await restorePreviousAppFocus()
            }

            await sendTranscriptionToDestination(processedText, destination: destinationService)

            // Log to history
            await MainActor.run {
                let historyEntry = CaptureHistoryEntry(
                    actions: captureActions,
                    modeName: modeManager.activeMode?.name ?? "Disabled",
                    modeId: modeManager.activeMode?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                    providerName: modeManager.activeMode is DisabledMode ? nil : modeManager.activeLLMProvider.name,
                    providerId: modeManager.activeMode is DisabledMode ? nil : modeManager.activeLLMProvider.id,
                    processedOutput: processedText,
                    destinationType: destinationService.name
                )
                captureHistory.addEntry(historyEntry)
            }

            // Close overlay
            await MainActor.run {
                closeOverlay()
            }
        }
    }

    func cancelRecording() {
        showResultsOverlay = false
        closeOverlay()
    }

    func toggleCapture() {
        if isCapturing {
            // Stop recording if active
            if isRecording {
                stopRecordingInOverlay()
            }

            // Finish capturing: show results overlay and hide minimized overlay
            showResultsOverlay = true
            showKeyboardInputOverlay = false
            isCapturing = false
        } else {
            // Start new capture
            Task {
                await startCapture()
            }
        }
    }

    /// Starts a new capture session
    /// - Parameter captureSelectedText: Whether to automatically capture selected text when starting.
    ///   Set to false when the calling action will handle text capture itself (e.g., clipboard shortcut)
    ///   to avoid capturing the same text twice.
    private func startCapture(captureSelectedText: Bool = true) async {
        // Store the currently active app BEFORE showing overlay
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        // Capture any selected text before showing overlay (unless caller will do it)
        if captureSelectedText {
            if let selectedText = await self.captureSelectedText(), !selectedText.isEmpty {
                print("📋 Captured selected text: \(selectedText.prefix(50))...")

                // Create capture action for selected text
                await MainActor.run {
                    let action = CaptureAction(source: .selectedText, text: selectedText)
                    captureActions.append(action)
                }
            }
        }

        await MainActor.run {
            isCapturing = true
            statusMessage = "Press R to start recording"
            print("✅ MenuBarController: Capture started")

            // Show HUD notification for capturing session start
            // let modeName = modeManager.activeMode?.name ?? "Unknown"
            // hudManager?.showCapturingStarted(mode: modeName)

            // Position overlay window
            positionCapturingWindow()
        }
    }

    private func handleToggleRecordingShortcut() {
        // Auto-start capture if not active
        if !isCapturing {
            print("🎙️ Starting capture and recording automatically")
            Task {
                await startCapture()
                toggleRecordingInOverlay()
            }
        } else {
            toggleRecordingInOverlay()
        }
    }

    func openPreview() {
        handlePreviewShortcut()
    }

    func addClipboardToCapture() {
        // Only work if capture is active
        guard isCapturing else {
            print("⚠️ Add clipboard ignored - no active capture")
            return
        }

        // Get text from clipboard and add to capture (reads existing clipboard)
        let pasteboard = NSPasteboard.general
        if let clipboardText = pasteboard.string(forType: .string), !clipboardText.isEmpty {
            let action = CaptureAction(source: .clipboard, text: clipboardText)
            captureActions.append(action)
            // hudManager?.showClipboardAdded()
            print("📋 Added clipboard text to capture: \(clipboardText.prefix(50))...")
        } else {
            print("⚠️ Clipboard is empty")
        }
    }

    private func handlePreviewShortcut() {
        // Only work if capture is active
        guard isCapturing else {
            print("⚠️ Preview shortcut ignored - no active capture")
            return
        }

        print("👁️ Opening capture preview window")

        // Open the preview window using callback
        openWindowCallback?("capture-preview")

        // Activate the app to bring window to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleAddKeyboardInputShortcut() {
        openKeyboardInputOverlay()
    }

    func openKeyboardInputOverlay() {
        // Auto-start capture if not active
        if !isCapturing {
            print("⌨️ Starting capture and opening keyboard input automatically")
            Task {
                await startCapture()
                openKeyboardInputOverlay()
            }
            return
        }

        print("⌨️ Opening keyboard input overlay")
        showKeyboardInputOverlay = true

        // Open the keyboard input window using callback
        openWindowCallback?("keyboard-input-overlay")

        // Activate the app to bring window to foreground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func addKeyboardInput(text: String) {
        let action = CaptureAction(source: .keyboardInput, text: text)
        captureActions.append(action)

        // Show button feedback
        keyboardInputJustAdded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.keyboardInputJustAdded = false
        }

        print("⌨️ Added keyboard input to capture: \(text.prefix(50))...")
    }

    func copySelectionAndAddToCapture() {
        // Auto-start capture if not active
        if !isCapturing {
            print("📋 Starting capture and adding clipboard automatically")
            Task {
                // Skip initial text capture since this action will capture it anyway
                await startCapture(captureSelectedText: false)
                copySelectionAndAddToCapture()
            }
            return
        }

        Task {
            // Simulate Cmd+C to copy selected text, then add to capture
            if let copiedText = await copySelectedText(), !copiedText.isEmpty {
                await MainActor.run {
                    // Create capture action for clipboard
                    let action = CaptureAction(source: .clipboard, text: copiedText)
                    captureActions.append(action)

                    print("📋 Added clipboard text to capture: \(copiedText.prefix(50))...")
                    statusMessage = "Added clipboard text"

                    // Show HUD notification
                    // hudManager?.showClipboardAdded()

                    // Reset status message after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.isRecording {
                            self.statusMessage = "Recording... Press R to stop"
                        } else if !self.capturedText.isEmpty {
                            self.statusMessage = "Press R to record more, or ⌘C/V/T to finish"
                        } else {
                            self.statusMessage = "Press R to start recording"
                        }
                    }
                }
            } else {
                await MainActor.run {
                    print("⚠️ No text selected to copy")
                    statusMessage = "No text selected"

                    // Reset status message after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.isRecording {
                            self.statusMessage = "Recording... Press R to stop"
                        } else if !self.capturedText.isEmpty {
                            self.statusMessage = "Press R to record more, or ⌘C/V/T to finish"
                        } else {
                            self.statusMessage = "Press R to start recording"
                        }
                    }
                }
            }
        }
    }

    private func copySelectedText() async -> String? {
        // Get current clipboard content
        let pasteboard = NSPasteboard.general
        let savedChangeCount = pasteboard.changeCount

        print("📋 Triggering Cmd+C to copy selected text...")

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

        // Wait for clipboard to update
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Check if clipboard changed (meaning text was selected)
        let newChangeCount = pasteboard.changeCount

        if newChangeCount != savedChangeCount {
            // Clipboard changed, get the new content
            let copiedText = pasteboard.string(forType: .string)
            print("✅ Copied selected text: \(copiedText ?? "[empty]")")
            return copiedText
        } else {
            // No text was selected
            print("ℹ️ No text was selected (clipboard unchanged)")
            return nil
        }
    }

    private func closeOverlay() {
        // Stop recording if active
        if isRecording {
            _ = audioRecorder.stopRecording()
        }

        // Clean up audio files from recording actions
        for action in captureActions where action.source == .recording {
            if let audioURL = action.audioFileURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        // Clear capture actions
        captureActions.removeAll()

        isCapturing = false
        showResultsOverlay = false
        showKeyboardInputOverlay = false
        isRecording = false
        isProcessing = false
        statusMessage = "Ready to capture"
        print("✅ MenuBarController: Overlay closed")
    }

    func toggleRecordingInOverlay() {
        if isRecording {
            stopRecordingInOverlay()
        } else {
            Task {
                await startRecordingInOverlay()
            }
        }
    }

    private func startRecordingInOverlay() async {
        let success = await audioRecorder.startRecording()
        await MainActor.run {
            if success {
                isRecording = true
                statusMessage = "Recording... Press R to stop"
                print("✅ MenuBarController: Recording started in overlay")

                // Show HUD notification
                // let modeName = modeManager.activeMode?.name ?? "Unknown"
                // hudManager?.showRecordingStarted(mode: modeName)
            } else {
                statusMessage = "Failed to start recording"
            }
        }
    }

    private func stopRecordingInOverlay() {
        guard let audioURL = audioRecorder.stopRecording() else {
            Task {
                await MainActor.run {
                    statusMessage = "Recording failed"
                    isRecording = false
                }
            }
            return
        }

        Task {
            await MainActor.run {
                isRecording = false
                isProcessing = true
                statusMessage = "Transcribing..."

                // Show HUD notification
                // let modeName = modeManager.activeMode?.name ?? "Unknown"
                // hudManager?.showRecordingStopped(mode: modeName)
            }

            do {
                let transcription = try await transcriptionProvider.transcribe(audioFileURL: audioURL)
                await handleTranscriptionForAccumulation(transcription, audioURL: audioURL)
            } catch {
                await handleTranscriptionError(error)
                // Clean up the audio file on error
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    private func handleTranscriptionForAccumulation(_ transcription: String, audioURL: URL) async {
        lastTranscription = transcription

        // Skip empty or whitespace-only transcriptions
        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscription.isEmpty else {
            print("⚠️ Skipping empty transcription")
            await MainActor.run {
                isProcessing = false
                statusMessage = "No speech detected. Press R to try again"
            }
            // Clean up the audio file for empty transcription
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        // Create capture action for recording
        await MainActor.run {
            let action = CaptureAction(source: .recording, text: trimmedTranscription, audioFileURL: audioURL)
            captureActions.append(action)

            isProcessing = false
            statusMessage = "Press R to record more, or ⌘C/V/T to finish"
            print("📝 Captured text: \(capturedText.prefix(100))...")
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

    private func positionCapturingWindow() {
        // Find the capturing window
        guard let capturingWindow = NSApp.windows.first(where: { $0.title == "Capturing" }) else {
            print("❌ MenuBarController: Could not find capturing window to position")
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

        // Position the capturing window in top-left corner of the target screen
        let screenFrame = screen.frame
        let margin: CGFloat = 20 // Distance from screen edge

        print("📍 MenuBarController: Positioning capturing window on screen: \(screen.localizedName)")

        // Position in top-left corner with margin
        let windowX = screenFrame.minX + margin
        let windowY = screenFrame.maxY - margin // maxY is top, position slightly below top edge

        // Set just the origin since we don't need to know window size for top-left positioning
        capturingWindow.setFrameOrigin(NSPoint(x: windowX, y: windowY))

        print("✅ Window positioned at: \(capturingWindow.frame)")
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

                // Show HUD notification for completion
                hudManager?.showSendingComplete(destination: destination.name)
            }

            // Focus restoration already happened in onPrepareSend callback

            // Reset status after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusMessage = "Ready to capture"
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
                self.statusMessage = "Ready to capture"
            }
        }
    }

    private func handleTranscriptionError(_ error: Error) async {
        print("Transcription error: \(error)")

        if let transcriptionError = error as? TranscriptionError {
            statusMessage = transcriptionError.localizedDescription ?? "Transcription failed"
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
