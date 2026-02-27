import Foundation
import CoreGraphics
import OSLog

@Observable
@MainActor
final class ModeSwitcherCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = ModeSwitcherPanel()

    /// Callback to set or clear a temporary output destination override on the active coordinators.
    /// Called with a UUID to set, or nil to clear.
    var onOutputDestinationOverride: ((UUID?) -> Void)?

    /// Tracks the currently active output destination override so the mode switcher
    /// can pre-populate its pending state when reopened.
    private(set) var currentOutputDestinationOverrideID: UUID?

    /// Called when the mode switcher panel becomes visible
    var onPanelShow: (() -> Void)?

    /// Called when the mode switcher panel is dismissed (any path: selection, escape, click outside, toggle)
    var onPanelHide: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        panel.onHide = { [weak self] in
            self?.onPanelHide?()
        }
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
        let activeModeID = settings.activeModeID
        panel.show(
            modes: settings.modes,
            activeModeID: activeModeID,
            outputDestinations: settings.outputDestinations,
            showHint: settings.showModeSwitcherHint,
            currentOutputDestinationOverrideID: currentOutputDestinationOverrideID,
            onSelect: { [weak self] id in
                guard let self else { return }
                let modeChanged = activeModeID != id
                self.settings.activeModeID = id
                if modeChanged {
                    self.currentOutputDestinationOverrideID = nil
                    self.onOutputDestinationOverride?(nil)
                }
                Logger.settings.info("Mode switched to \(id)")
            },
            onOutputDestinationSelect: { [weak self] destinationID in
                guard let self else { return }
                self.currentOutputDestinationOverrideID = destinationID
                self.onOutputDestinationOverride?(destinationID)
                if let destinationID {
                    Logger.settings.info("Output destination override set to \(destinationID)")
                } else {
                    Logger.settings.info("Output destination override cleared")
                }
            }
        )
        onPanelShow?()
    }

    /// Clears the tracked override (called after dictation consumes or cancels the override).
    func clearOutputDestinationOverride() {
        currentOutputDestinationOverrideID = nil
    }

    private func toggleSwitcher() {
        if panel.isVisible {
            panel.hide()
        } else {
            showSwitcher()
        }
    }
}
