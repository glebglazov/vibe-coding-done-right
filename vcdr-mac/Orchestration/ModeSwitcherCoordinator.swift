import Combine
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
    private let styleResolution: StyleResolutionPipeline

    @ObservationIgnored weak var delegate: ModeSwitcherCoordinatorDelegate?

    init(
        settings: AppSettings,
        overrides: SessionOverrides,
        styleResolution: StyleResolutionPipeline
    ) {
        self.settings = settings
        self.overrides = overrides
        self.styleResolution = styleResolution
        observeHotkeySettings()
    }

    func setupHotkey() {
        let binding = settings.modeSwitcherHotkey
        guard binding.isAssigned else {
            hotkeyManager.unregister()
            Logger.hotkeys.info("Mode switcher hotkey unassigned, unregistered")
            return
        }

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
            currentStyleName: styleResolution.currentStyle.name,
            isStyleOverridden: styleResolution.hasActiveOverride,
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
            onDismiss: onDismiss,
            onCycleStyle: { [weak self] in
                self?.cycleStyle()
            }
        )

        vm.onParameterOverride = { [weak self, weak vm] parameterID, value in
            guard let self else { return }
            if let vm, vm.modes[vm.highlightedIndex].id != self.settings.activeModeID {
                let modeID = vm.modes[vm.highlightedIndex].id
                self.settings.activeModeID = modeID
                vm.activeModeID = modeID
                Logger.settings.info("Mode auto-activated via parameter change: \(modeID)")
            }
            self.overrides.parameterOverrides[parameterID] = value
        }

        styleResolution.onStyleChanged = { [weak vm, weak self] newStyle in
            guard let vm, let self else { return }
            vm.currentStyleName = newStyle.name
            vm.isStyleOverridden = self.styleResolution.hasActiveOverride
        }

        return vm
    }

    // MARK: - Style Cycling

    private func cycleStyle() {
        let newStyle = styleResolution.cycleToNextStyle()

        if let viewModel = panel.viewModel {
            viewModel.currentStyleName = newStyle.name
            viewModel.isStyleOverridden = styleResolution.hasActiveOverride
        }

        Logger.settings.info(
            "Style cycled to: \(newStyle.name) (overridden: \(self.styleResolution.hasActiveOverride))"
        )
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
        if panel.isVisible {
            panel.hide()
            delegate?.modeSwitcherDidHide()
            return
        }

        showSwitcher()
    }

    // MARK: - Settings + Re-registration

    /// Re-arms this coordinator's tap from `settings`, so a re-bound Mode Switcher
    /// shortcut applies at once. See `CaptureSession.observeHotkeySettings()`.
    private func observeHotkeySettings() {
        withObservationTracking {
            _ = settings.hotkeySettings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setupHotkey()
                self.observeHotkeySettings()
            }
        }
    }

    func setHotkeySuppressed(_ suppressed: Bool) {
        hotkeyManager.isSuppressed = suppressed
    }
}
