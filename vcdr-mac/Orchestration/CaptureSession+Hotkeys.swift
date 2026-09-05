import Foundation
import CoreGraphics

extension CaptureSession {

    // MARK: - Registration

    /// Releases first and claims after, unconditionally: the window server refuses
    /// a second registration of a combination that is still claimed, so re-arming
    /// the same shortcut only works in that order.
    func setupToggleHotkey() {
        toggleClaim?.release()
        toggleClaim = nil

        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned, !isToggleHotkeySuppressed else { return }

        toggleClaim = hotkeyRegistry.claim(binding) { [weak self] in
            self?.toggle()
        }
    }

    func setupCancelHotkey() {
        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned else {
            cancelHotkey.isEnabled = false
            cancelHotkey.unregister()
            return
        }
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
        // Enablement belongs to the phase, not to the registration. Re-binding
        // mid-capture must not leave cancel dead for the rest of that run.
        updateCancelHotkey()
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

    // MARK: - Settings tracking

    /// Keeps every hotkey this session owns a projection of `settings`, so a
    /// re-bound shortcut is armed the moment it is set — including mid-capture,
    /// where the old binding has already been released. The UI writes settings
    /// and nothing else; no screen has to remember to re-register.
    ///
    /// `withObservationTracking` fires its handler once, before the write lands —
    /// hence the main-actor hop to read the new value, and the re-arm afterwards.
    func observeHotkeySettings() {
        withObservationTracking {
            _ = settings.hotkeySettings
            _ = settings.outputDestinations
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setupToggleHotkey()
                self.setupCancelHotkey()
                self.setupDestinationHotkeys()
                self.observeHotkeySettings()
            }
        }
    }
}
