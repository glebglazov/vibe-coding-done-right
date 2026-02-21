import AppKit
import CoreAudio
import OSLog

@MainActor
final class MediaPlaybackController {
    private var didPauseMedia = false

    // MARK: - Media key constants

    /// NX_KEYTYPE_PLAY — the system play/pause media key
    private static let mediaPlayPauseKeyCode: Int32 = 16
    private static let keyDownFlags: UInt32 = 0xA00
    private static let keyUpFlags: UInt32 = 0xB00
    private static let systemDefinedSubtype: Int16 = 8

    /// Pauses media only if audio output is currently active (i.e. something is actually
    /// producing sound). This avoids the bug where toggling play/pause with nothing playing
    /// would accidentally START playback on resume.
    func pauseIfNeeded() {
        guard Self.isAudioOutputActive() else {
            Logger.audio.info("No audio output active, skipping pause")
            return
        }

        didPauseMedia = true
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media pause key")
    }

    func resumeIfNeeded() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media resume key")
    }

    // MARK: - CoreAudio output detection

    /// Checks whether any process is currently sending audio to the default output device.
    /// Uses the public CoreAudio API — no private frameworks or entitlements required.
    private static func isAudioOutputActive() -> Bool {
        var defaultDevice = AudioObjectID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &defaultDevice
        )
        guard status == noErr, defaultDevice != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        size = UInt32(MemoryLayout<UInt32>.size)

        let status2 = AudioObjectGetPropertyData(
            defaultDevice,
            &address,
            0, nil,
            &size,
            &isRunning
        )
        guard status2 == noErr else { return false }

        return isRunning != 0
    }

    // MARK: - Media key simulation

    private static func sendMediaKeyEvent() {
        postMediaKey(flags: keyDownFlags)
        postMediaKey(flags: keyUpFlags)
    }

    private static func postMediaKey(flags: UInt32) {
        let data1 = Int((mediaPlayPauseKeyCode << 16) | Int32(bitPattern: flags))
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: systemDefinedSubtype,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
