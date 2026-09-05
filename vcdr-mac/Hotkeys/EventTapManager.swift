import Foundation
import ApplicationServices
import OSLog

/// Manages a CGEvent tap lifecycle: creation, run loop source, enable/disable, and cleanup.
/// Used by ModeSwitcherPanel to avoid duplicating tap boilerplate.
final class EventTapManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Creates and installs a CGEvent tap on the main run loop.
    /// - Parameters:
    ///   - eventMask: Bitmask of CGEventType values to listen for.
    ///   - callback: The tap callback invoked for matching events.
    ///   - userInfo: Opaque pointer forwarded to the callback.
    /// - Returns: `true` if the tap was created and installed successfully.
    func install(
        eventMask: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> Bool {
        uninstall()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        )

        guard let eventTap else { return false }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    /// Removes the event tap and its run loop source.
    func uninstall() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            self.eventTap = nil
        }
    }

    /// Re-enables the tap after macOS disabled it (tapDisabledByTimeout/tapDisabledByUserInput).
    func reEnableTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    var isInstalled: Bool { eventTap != nil }

    deinit { uninstall() }
}
