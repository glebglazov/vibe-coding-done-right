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
    private(set) var initializationStatus = "Loading model..."
    private(set) var hasMicrophonePermission = false
    private(set) var hasAccessibilityPermission = false

    var needsPermissionAttention: Bool {
        !hasMicrophonePermission || !hasAccessibilityPermission
    }

    private var permissionTimer: Timer?

    init() {
        let settings = AppSettings()
        let provider = ParakeetProvider()
        self.settings = settings
        self.transcriptionProvider = provider
        self.coordinator = PushToTalkCoordinator(settings: settings, transcriptionProvider: provider)
    }

    func initialize() async {
        requestAllPermissions()
        checkPermissions()
        startPermissionPolling()

        do {
            // Poll the provider's init phase so the UI updates in real time
            let phasePoller = Task {
                while !Task.isCancelled {
                    let phase = await transcriptionProvider.initPhase
                    switch phase {
                    case .notStarted, .downloading:
                        initializationStatus = "Downloading model..."
                    case .compiling:
                        initializationStatus = "Compiling model..."
                    case .ready:
                        break
                    }
                    try? await Task.sleep(for: Self.phasePollingInterval)
                }
            }

            try await transcriptionProvider.initialize()
            phasePoller.cancel()

            isTranscriptionReady = true
            initializationStatus = "Ready"
            if hasAccessibilityPermission {
                coordinator.setupHotkey()
            }
            Logger.app.info("App fully initialized")
        } catch {
            initializationStatus = "Failed: \(error.localizedDescription)"
            Logger.app.error("Initialization failed: \(error)")
        }
    }

    private func checkPermissions() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    // MARK: - Constants

    private static let phasePollingInterval: Duration = .milliseconds(200)
    private static let permissionPollInterval: TimeInterval = 2

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: Self.permissionPollInterval,
            repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let wasAccessible = self.hasAccessibilityPermission
            self.checkPermissions()

            // Register hotkey as soon as accessibility is granted
            if !wasAccessible && self.hasAccessibilityPermission {
                self.coordinator.setupHotkey()
                Logger.app.info("Accessibility granted, hotkey registered")
            }

            // Stop polling once both permissions are granted
            if self.hasMicrophonePermission && self.hasAccessibilityPermission {
                timer.invalidate()
                self.permissionTimer = nil
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

    deinit {
        permissionTimer?.invalidate()
    }
}
