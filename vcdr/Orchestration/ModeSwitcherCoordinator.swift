import Foundation
import CoreGraphics
import OSLog

@Observable
@MainActor
final class ModeSwitcherCoordinator {
    private let settings: AppSettings
    private let hotkeyManager = GlobalHotkeyManager()
    private let panel = ModeSwitcherPanel()
    private let overrides: SessionOverrides

    @ObservationIgnored weak var delegate: ModeSwitcherCoordinatorDelegate?

    init(settings: AppSettings, overrides: SessionOverrides) {
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
        let modes = settings.switcherModes
        let activeIndex = modes.firstIndex(where: { $0.id == settings.activeModeID }) ?? 0

        let vm = ModeSwitcherViewModel(
            modes: modes,
            highlightedIndex: activeIndex,
            activeModeID: settings.activeModeID,
            parameterOverrides: overrides.parameterOverrides,
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
        let modes = settings.switcherModes
        guard !modes.isEmpty else { return }

        delegate?.modeSwitcherWillShow()

        let vm = makeViewModel(onDismiss: { [weak self] in
            self?.panel.hide()
            self?.delegate?.modeSwitcherDidHide()
        })
        vm.isRecording = delegate?.isRecordingActive ?? false
        panel.show(viewModel: vm)
    }

    func hideSwitcher() {
        panel.hide()
        delegate?.modeSwitcherDidHide()
    }

    /// Confirms the currently highlighted mode and hides the switcher.
    /// Acts as if the user pressed Enter. confirmAndHide triggers onSelect → onDismiss → delegate.modeSwitcherDidHide().
    func confirmAndHideSwitcher() {
        guard panel.isVisible else { return }
        panel.confirmAndHide()
    }

    private func toggleSwitcher() {
        // 1. If standalone panel is showing, hide it
        if panel.isVisible {
            panel.hide()
            delegate?.modeSwitcherDidHide()
            return
        }

        // 2. Show standalone panel
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
