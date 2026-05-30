import Foundation
import OSLog

/// Keyboard Channel command + settings listeners: registers the Darwin
/// notification observers, dispatches start/stop commands the keyboard
/// extension posts, and re-reads cross-process settings changes.
extension RecordingFlowCoordinator {

    /// Listens for commands from the keyboard extension via Darwin notifications.
    /// Safe to call multiple times — removes the previous observer before re-registering.
    func setupCommandListener() {
        // Remove previous observer if present (e.g. on scene re-entry)
        if let token = commandObserverToken {
            NotificationCenter.default.removeObserver(token)
            commandObserverToken = nil
        }

        DarwinNotificationCenter.observe(
            KeyboardChannel.commandNotificationName,
            localName: .darwinCommand
        )
        commandObserverToken = NotificationCenter.default.addObserver(
            forName: .darwinCommand,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.handleCommand()
            }
        }

        // Listen for settings changes from the keyboard extension
        if let token = settingsObserverToken {
            NotificationCenter.default.removeObserver(token)
            settingsObserverToken = nil
        }
        DarwinNotificationCenter.observe(
            SharedConstants.settingsNotificationName,
            localName: .darwinSettingsChanged
        )
        settingsObserverToken = NotificationCenter.default.addObserver(
            forName: .darwinSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handleSettingsChanged()
            }
        }
    }

    private func handleSettingsChanged() {
        SharedConstants.sharedDefaults.synchronize()
        selectedPromptMode = SessionSettings.effectiveAIMode()
        currentTextStyle = SessionSettings.effectiveTextStyle()
    }

    /// Re-reads session/default state from shared storage. Called after the
    /// cold-launch boot sequence runs (migration + session clear) so any state
    /// that landed after `@State` initialized the coordinator is picked up.
    func refreshSettingsFromStorage() {
        handleSettingsChanged()
    }

    private func handleCommand() async {
        guard let command = keyboardChannel.readAndClearCommand() else { return }

        switch command {
        case .startRecording:
            Logger.app.info("Received start command from keyboard")
            await startRecording(fromDeepLink: true)
        case .stopRecording:
            Logger.app.info("Received stop command from keyboard")
            await stopAndTranscribe(sendToKeyboard: true)
        }
    }
}
