import SwiftUI
import AVFoundation
import ApplicationServices
import OSLog

@Observable
final class AppDependencies {
    let settings: AppSettings
    let transcriptionProvider: ParakeetProvider
    let coordinator: PushToTalkCoordinator

    private(set) var isTranscriptionReady = false
    private(set) var initializationStatus = "Downloading Parakeet model..."

    init() {
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        self.coordinator = PushToTalkCoordinator(settings: settings, transcriptionProvider: provider)
    }

    func initialize() async {
        requestAllPermissions()

        do {
            try await transcriptionProvider.initialize()
            isTranscriptionReady = true
            initializationStatus = "Ready"
            setupHotkeyWhenAccessible()
            Logger.app.info("App fully initialized")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Initialization failed: \(error)")
        }
    }

    private func setupHotkeyWhenAccessible() {
        if AXIsProcessTrusted() {
            coordinator.setupHotkey()
            return
        }

        Logger.app.info("Waiting for accessibility permissions...")
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.coordinator.setupHotkey()
                Logger.app.info("Accessibility granted, hotkey registered")
            }
        }
    }

    private func requestAllPermissions() {
        // Microphone
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Logger.app.info("Microphone permission: \(granted)")
            }
        }

        // Accessibility (needed for global hotkey event tap)
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Logger.app.info("Requested accessibility permissions")
        }
    }
}
