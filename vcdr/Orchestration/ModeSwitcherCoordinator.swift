import Foundation
import CoreGraphics
import OSLog

@Observable
@MainActor
final class ModeSwitcherCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = ModeSwitcherPanel()

    /// Callback to set a temporary output destination override on the active coordinators
    var onOutputDestinationOverride: ((UUID) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func setupHotkey() {
        let binding = settings.modeSwitcherHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Mode switcher hotkey unassigned, unregistered")
            return
        }

        // Use assumeIsolated instead of Task { @MainActor in } to execute
        // synchronously. The CGEvent tap callback runs on the main thread, but
        // Task scheduling can be starved by key-repeat events during recording.
        hotkeyManager.onKeyDown = { [weak self] in
            MainActor.assumeIsolated {
                self?.toggleSwitcher()
            }
        }
        hotkeyManager.onKeyUp = nil

        let keyCode = CGKeyCode(binding.keyCode)
        let modifiers = CGEventFlags(rawValue: binding.modifiers)
        _ = hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
    }

    func updateHotkey() {
        setupHotkey()
    }

    func showSwitcher() {
        guard !settings.modes.isEmpty else { return }
        panel.show(
            modes: settings.modes,
            activeModeID: settings.activeModeID,
            outputDestinations: settings.outputDestinations,
            showHint: settings.showModeSwitcherHint,
            onSelect: { [weak self] id in
                guard let self else { return }
                self.settings.activeModeID = id
                Logger.settings.info("Mode switched to \(id)")
            },
            onOutputDestinationSelect: { [weak self] destinationID in
                guard let self else { return }
                self.onOutputDestinationOverride?(destinationID)
                Logger.settings.info("Output destination override set to \(destinationID)")
            }
        )
    }

    private func toggleSwitcher() {
        if panel.isVisible {
            panel.hide()
        } else {
            showSwitcher()
        }
    }
}
