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
        guard binding.isAssigned, !isToggleHotkeySuppressed else { return }

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
              !isCancelHotkeySuppressed,
              !isSuspendedForModeSwitcher
        else { return }

        cancelClaim = hotkeyRegistry.claim(binding) { [weak self] in
            self?.cancel()
        }
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
