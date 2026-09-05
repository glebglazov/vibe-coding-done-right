import Carbon
import Foundation
import OSLog

/// Claims key combinations through Carbon's `RegisterEventHotKey`.
///
/// This exists because of Secure Event Input. While any process on the machine
/// holds that flag, macOS silently stops delivering key events to every session
/// event tap — the tap still reports itself installed, nothing is logged, and the
/// user presses the key and gets nothing (see `SecureInputMonitor`). A Carbon
/// registration is answered by the window server instead, and keeps firing.
///
/// The whole app shares one Carbon event handler: registrations are process-wide
/// and arrive already identified by `EventHotKeyID`, so a second handler would only
/// re-dispatch the same events. Owners get a `HotkeyClaim` each instead.
@MainActor
final class CarbonHotkeyRegistry: HotkeyRegistry {

    // MARK: - Constants

    /// Four-character code stamped into every `EventHotKeyID` this registry issues.
    /// Carbon scopes ids by signature, so this keeps ours apart from any other
    /// registrant inside the process.
    private static let signature: OSType = "VCDR".utf8.reduce(into: OSType(0)) { code, byte in
        code = (code << 8) | OSType(byte)
    }

    /// `RegisterEventHotKey` takes no options.
    private static let noRegistrationOptions: OptionBits = 0

    private struct Registration {
        let hotKeyRef: EventHotKeyRef
        let onPress: () -> Void
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]
    private var lastIssuedID: UInt32 = 0

    // MARK: - HotkeyRegistry

    func claim(_ binding: HotkeyBinding, onPress: @escaping () -> Void) -> HotkeyClaim? {
        guard binding.isAssigned, installHandlerIfNeeded() else { return nil }

        lastIssuedID += 1
        let id = lastIssuedID
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            Self.noRegistrationOptions,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            Logger.hotkeys.error("Failed to claim \(binding.displayString): OSStatus \(status)")
            return nil
        }

        registrations[id] = Registration(hotKeyRef: hotKeyRef, onPress: onPress)
        Logger.hotkeys.info("Hotkey claimed: \(binding.displayString)")
        return HotkeyClaim { [weak self] in self?.release(id) }
    }

    // MARK: - Registration lifecycle

    private func release(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        let status = UnregisterEventHotKey(registration.hotKeyRef)
        if status != noErr {
            Logger.hotkeys.error("Failed to release hotkey claim: OSStatus \(status)")
        }
    }

    /// Installs the app's one Carbon handler, on the first claim that needs it.
    /// - Returns: `false` when the handler could not be installed, which makes every
    ///   claim fail rather than hand back a handle nothing would ever fire.
    private func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }

        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo -> OSStatus in
                guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard read == noErr else { return read }

                // Carbon dispatches this handler on the main thread, from the event
                // loop `NSApplication.run()` is already turning — so the owner's
                // reaction runs synchronously, without DispatchQueue.main.async or a
                // MainActor Task in between. Both of those can be delayed by seconds
                // when the MainActor executor is stalled, which is exactly the moment
                // a user is pressing the key to stop a recording.
                let registry = Unmanaged<CarbonHotkeyRegistry>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated { registry.dispatch(hotKeyID) }
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        guard status == noErr else {
            Logger.hotkeys.error("Failed to install the Carbon hotkey handler: OSStatus \(status)")
            return false
        }
        return true
    }

    private func dispatch(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == Self.signature,
              let registration = registrations[hotKeyID.id]
        else { return OSStatus(eventNotHandledErr) }

        registration.onPress()
        return noErr
    }

    deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
