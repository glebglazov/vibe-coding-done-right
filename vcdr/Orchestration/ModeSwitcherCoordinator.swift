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

    /// Callback to set parameter overrides on the recording coordinator
    var onParameterOverride: ((UUID, String) -> Void)?

    /// Callback when a mode is selected (so the indicator can update parameter labels)
    var onModeSelected: ((UUID) -> Void)?

    /// Reads current parameter overrides for display in the mode switcher
    var currentParameterOverrides: (() -> [UUID: String])?

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
        let currentOverrides = currentParameterOverrides?() ?? [:]
        panel.show(
            modes: settings.modes,
            activeModeID: settings.activeModeID,
            outputDestinations: settings.outputDestinations,
            showHint: settings.showModeSwitcherHint,
            parameterOverrides: currentOverrides,
            onSelect: { [weak self] id in
                guard let self else { return }
                self.settings.activeModeID = id
                self.onModeSelected?(id)
                Logger.settings.info("Mode switched to \(id)")
            },
            onOutputDestinationSelect: { [weak self] destinationID in
                guard let self else { return }
                self.onOutputDestinationOverride?(destinationID)
                Logger.settings.info("Output destination override set to \(destinationID)")
            },
            onParameterOverride: { [weak self] parameterID, value in
                guard let self else { return }
                self.onParameterOverride?(parameterID, value)
            }
        )
    }

    func hideSwitcher() {
        panel.hide()
    }

    /// Confirms the currently highlighted mode and hides the switcher.
    /// Acts as if the user pressed Enter.
    func confirmAndHideSwitcher() {
        guard panel.isVisible else { return }
        panel.confirmAndHide()
    }

    private func toggleSwitcher() {
        if panel.isVisible {
            panel.hide()
        } else {
            showSwitcher()
        }
    }
}
