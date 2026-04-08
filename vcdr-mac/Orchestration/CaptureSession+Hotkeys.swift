import Foundation
import CoreGraphics

extension CaptureSession {

    // MARK: - Registration

    func setupToggleHotkey() {
        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned else {
            toggleHotkey.unregister()
            return
        }
        toggleHotkey.onKeyDown = { [weak self] in
            self?.toggle()
        }
        toggleHotkey.onKeyUp = nil
        _ = toggleHotkey.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func setupCancelHotkey() {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else {
            cancelHotkey.isEnabled = false
            return
        }
        cancelHotkey.isEnabled = false
        cancelHotkey.onKeyDown = { [weak self] in
            guard let self else { return }
            switch self.status.phase {
            case .preparingToRecord, .recording, .transcribing, .executing, .awaitingPreview:
                self.cancel()
            default:
                break
            }
        }
        cancelHotkey.onKeyUp = nil
        _ = cancelHotkey.register(
            keyCode: CGKeyCode(binding.keyCode),
            modifiers: CGEventFlags(rawValue: binding.modifiers)
        )
    }

    func setupDestinationHotkeys() {
        let bindings = settings.outputDestinations.map { ($0.id, $0.activationHotkey) }
        destinationHotkey.onDestinationMatched = { [weak self] destinationID in
            guard let self else { return }
            // Smuggle the override into the current run so it's consumed when transcription finishes.
            self.run?.destinationOverrideID = destinationID
            self.stopRecordingAndTranscribe()
        }
        destinationHotkey.register(bindings: bindings)
    }

    /// Enables the cancel hotkey iff the session is in an active capture phase.
    func updateCancelHotkey() {
        switch status.phase {
        case .preparingToRecord, .recording, .transcribing, .executing, .awaitingPreview:
            cancelHotkey.isEnabled = true
        default:
            cancelHotkey.isEnabled = false
        }
    }

    // MARK: - Settings updates

    func updateToggleRecordingKeyCode(_ code: UInt16) {
        settings.toggleRecordingHotkey.keyCode = code
        setupToggleHotkey()
    }

    func updateToggleRecordingModifiers(_ mods: UInt64) {
        settings.toggleRecordingHotkey.modifiers = mods
        setupToggleHotkey()
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
