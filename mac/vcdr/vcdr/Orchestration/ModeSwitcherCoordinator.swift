import Foundation
import CoreGraphics
import OSLog

@Observable
@MainActor
final class ModeSwitcherCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = ModeSwitcherPanel()

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

        hotkeyManager.onKeyDown = { [weak self] in
            Task { @MainActor in
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
            activeModeID: settings.activeModeID
        ) { [weak self] selectedID in
            self?.settings.activeModeID = selectedID
            Logger.settings.info("Mode switched via popup")
        }
    }

    private func toggleSwitcher() {
        if panel.isVisible {
            panel.hide()
        } else {
            showSwitcher()
        }
    }
}
