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

    func setupCancelHotkey() {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else {
            cancelHotkeyManager.isEnabled = false
            return
        }
        cancelHotkeyManager.isEnabled = false
        cancelHotkeyManager.onKeyDown = { [weak self] in
            guard let self else { return }
            if self.state == .preparingToRecord || self.state == .recording || self.state == .transcribing {
                self.cancelRecording()
            }
        }
        cancelHotkeyManager.onKeyUp = nil
        _ = cancelHotkeyManager.register(
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

    func updateCancelHotkey() {
        let recordingActive = (state == .preparingToRecord || state == .recording || state == .transcribing)
        cancelHotkeyManager.isEnabled = recordingActive
    }

    func suspendCancelHotkey() {
        cancelHotkeyManager.isEnabled = false
    }

    func resumeCancelHotkey() {
        updateCancelHotkey()
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
        setupCancelHotkey()
    }

    func updateCancelRecordingModifiers(_ mods: UInt64) {
        settings.cancelRecordingHotkey.modifiers = mods
        setupCancelHotkey()
    }
}
