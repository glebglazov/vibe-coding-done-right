import Foundation
import OSLog

/// Keyboard Channel command + settings listeners: registers the Darwin
/// notification observers, runs the commands the keyboard extension sends,
/// and re-reads cross-process settings changes.
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
                await self.handleCommands()
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
        selectedPromptMode = SettingOverrides.effectiveAIMode()
        currentTextStyle = SettingOverrides.effectiveTextStyle()
    }

    func refreshSettingsFromStorage() {
        handleSettingsChanged()
    }

    /// Runs every command not yet taken, in the order the keyboard sent them.
    private func handleCommands() async {
        for command in keyboardWire.claim(keyboardChannel.readCommands()) {
            await handle(command)
        }
    }

    private func handle(_ command: KeyboardCommand) async {
        switch command.kind {
        case .start:
            Logger.app.info("Received start command from keyboard")
            await startRecording(origin: .keyboard)
        case .stop(let run):
            Logger.app.info("Received stop command from keyboard")
            await stopKeyboardRun(run)
        case .discard(let run):
            // Fail-closed on staleness (ADR-0003): a Discard that sat queued
            // across a suspend is dropped, whatever run is current now.
            guard Date().timeIntervalSince(command.sentAt) < KeyboardChannel.discardFreshnessWindow else {
                Logger.app.info("Dropped stale Discard from keyboard")
                return
            }
            guard activeRun?.run.id == run else {
                Logger.app.info("Dropped Discard from keyboard — its run is not current")
                return
            }
            Logger.app.info("Received Discard from keyboard")
            await discardRecording()
        }
    }
}
