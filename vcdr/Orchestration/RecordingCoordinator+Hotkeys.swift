import Foundation
import AppKit

extension RecordingCoordinator {

    func setupToggleRecordingHotkey() {
        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned else {
            toggleRecordingHotkeyManager.unregister()
            return
        }

        toggleRecordingHotkeyManager.onKeyDown = { [weak self] in
            self?.toggleRecording()
        }
        toggleRecordingHotkeyManager.onKeyUp = nil

        _ = toggleRecordingHotkeyManager.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func setupEscCancel() {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else {
            escCancelManager.isEnabled = false
            return
        }
        escCancelManager.isEnabled = false
        escCancelManager.onKeyDown = { [weak self] in
            self?.cancelRecording()
        }
        escCancelManager.onKeyUp = nil
        _ = escCancelManager.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func setupDestinationHotkeys() {
        let bindings = settings.outputDestinations.map { ($0.id, $0.activationHotkey) }
        destinationHotkeyManager.onDestinationMatched = { [weak self] destinationID in
            guard let self else { return }
            self.pendingDestinationOverride = destinationID
            self.stopRecordingAndTranscribe()
        }
        destinationHotkeyManager.register(bindings: bindings)
    }

    func updateEscCancel() {
        escCancelManager.isEnabled = (state == .preparingToRecord || state == .recording || state == .transcribing)
    }

    func suspendEscCancel() {
        escCancelManager.isEnabled = false
    }

    func resumeEscCancel() {
        updateEscCancel()
    }

    // MARK: - Settings + Re-registration

    func updateToggleRecordingKeyCode(_ code: UInt16) {
        settings.toggleRecordingHotkey.keyCode = code
        setupToggleRecordingHotkey()
    }

    func updateToggleRecordingModifiers(_ mods: UInt64) {
        settings.toggleRecordingHotkey.modifiers = mods
        setupToggleRecordingHotkey()
    }

    func updateCancelRecordingKeyCode(_ code: UInt16) {
        settings.cancelRecordingHotkey.keyCode = code
        setupEscCancel()
    }

    func updateCancelRecordingModifiers(_ mods: UInt64) {
        settings.cancelRecordingHotkey.modifiers = mods
        setupEscCancel()
    }
}
