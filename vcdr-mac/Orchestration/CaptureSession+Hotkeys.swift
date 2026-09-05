import Foundation

extension CaptureSession {

    // MARK: - Registration

    /// Releases first and claims after, unconditionally: the window server refuses
    /// a second registration of a combination that is still claimed, so re-arming
    /// the same shortcut only works in that order.
    func setupToggleHotkey() {
        toggleClaim?.release()
        toggleClaim = nil

        let binding = settings.toggleRecordingHotkey
        guard binding.isAssigned else { return }

        toggleClaim = hotkeyRegistry.claim(binding) { [weak self] in
            self?.toggle()
        }
    }

    /// Cancel is claimed iff there is a capture to cancel and nothing is holding
    /// the claim back. Called from `setStatus`, so a re-bind mid-capture re-arms
    /// for the run in flight and every terminal transition hands the combination
    /// back. Releases first and claims after, for the same reason the toggle does.
    func setupCancelHotkey() {
        cancelClaim?.release()
        cancelClaim = nil

        let binding = settings.cancelRecordingHotkey
        guard binding.isAssigned,
              status.phase.hasCaptureToCancel,
              !isSuspendedForModeSwitcher
        else { return }

        cancelClaim = hotkeyRegistry.claim(binding) { [weak self] in
            self?.cancel()
        }
    }

    /// The Activation Hotkeys are claimed iff a recording is running. Their
    /// Modifier Expansion covers whole modifier combinations of a key — a
    /// modifier-less binding covers Command-C — so holding them any longer would
    /// swallow ordinary shortcuts system-wide. Called from `setStatus` alongside
    /// cancel, so no exit path can leave them claimed.
    func setupDestinationHotkeys() {
        guard case .recording = status.phase else {
            destinationHotkey.disarm()
            return
        }

        destinationHotkey.arm(
            bindings: settings.outputDestinations.map { (id: $0.id, hotkey: $0.activationHotkey) }
        )
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
