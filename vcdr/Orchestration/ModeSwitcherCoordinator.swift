import Foundation
import CoreGraphics
import OSLog

@Observable
@MainActor
final class ModeSwitcherCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = ModeSwitcherPanel()
    private let overrides: ConversationOverrides

    @ObservationIgnored weak var delegate: ModeSwitcherCoordinatorDelegate?

    init(settings: AppSettings, overrides: ConversationOverrides) {
        self.settings = settings
        self.overrides = overrides
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

    /// Creates a ModeSwitcherViewModel with standard callbacks.
    /// `onDismiss` is caller-provided to handle context-specific cleanup.
    func makeViewModel(onDismiss: @escaping () -> Void) -> ModeSwitcherViewModel {
        let modes = settings.visibleModes
        let activeIndex = modes.firstIndex(where: { $0.id == settings.activeModeID }) ?? 0

        let vm = ModeSwitcherViewModel(
            modes: modes,
            highlightedIndex: activeIndex,
            activeModeID: settings.activeModeID,
            outputDestinations: settings.outputDestinations,
            showHint: settings.showModeSwitcherHint,
            parameterOverrides: overrides.parameterOverrides,
            activeDestinationOverrideID: overrides.destinationOverride,
            onSelect: { [weak self] id in
                guard let self else { return }
                self.settings.activeModeID = id
                onDismiss()
                Logger.settings.info("Mode switched to \(id)")
            },
            onActivate: { [weak self] id in
                guard let self else { return }
                self.settings.activeModeID = id
                Logger.settings.info("Mode activated (no dismiss): \(id)")
            },
            onOutputDestinationSelect: { [weak self] destinationID in
                guard let self else { return }
                self.overrides.destinationOverride = destinationID
                Logger.settings.info("Output destination override set to \(String(describing: destinationID))")
            },
            onParameterOverride: { _ , _ in },
            onDismiss: onDismiss
        )

        vm.onParameterOverride = { [weak self, weak vm] parameterID, value in
            guard let self else { return }
            // Activate the mode whose parameters are being changed
            if let vm, vm.modes[vm.highlightedIndex].id != self.settings.activeModeID {
                let modeID = vm.modes[vm.highlightedIndex].id
                self.settings.activeModeID = modeID
                vm.activeModeID = modeID
                Logger.settings.info("Mode auto-activated via parameter change: \(modeID)")
            }
            self.overrides.parameterOverrides[parameterID] = value
        }

        return vm
    }

    func showSwitcher() {
        let modes = settings.visibleModes
        guard !modes.isEmpty else { return }

        let vm = makeViewModel(onDismiss: { [weak self] in
            self?.panel.hide()
        })
        panel.show(viewModel: vm)
    }

    func hideSwitcher() {
        panel.hide()
    }

    /// Confirms the currently highlighted mode and hides the switcher.
    /// Acts as if the user pressed Enter. Works for both standalone and contextual.
    func confirmAndHideSwitcher() {
        if panel.isVisible {
            panel.confirmAndHide()
            return
        }
        // Try contextual dismiss (confirm is handled via the VM's onSelect callback)
        if delegate?.modeSwitcherShouldDismissContextual() == true {
            delegate?.modeSwitcherDidHideContextual()
        }
    }

    private func toggleSwitcher() {
        // 1. If contextual mode list is showing, dismiss it
        if delegate?.modeSwitcherShouldDismissContextual() == true {
            delegate?.modeSwitcherDidHideContextual()
            return
        }

        // 2. If standalone panel is showing, hide it
        if panel.isVisible {
            panel.hide()
            return
        }

        // 3. Try contextual host first
        if delegate?.modeSwitcherShouldShowContextual() == true {
            delegate?.modeSwitcherDidShowContextual()
            return
        }

        // 4. Standalone panel (existing behavior)
        showSwitcher()
    }

    // MARK: - Settings + Re-registration

    func updateModeSwitcherKeyCode(_ code: UInt16) {
        settings.modeSwitcherHotkey.keyCode = code
        setupHotkey()
    }

    func updateModeSwitcherModifiers(_ mods: UInt64) {
        settings.modeSwitcherHotkey.modifiers = mods
        setupHotkey()
    }
}
