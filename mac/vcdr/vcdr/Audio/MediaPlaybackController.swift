import AppKit
import OSLog

@MainActor
final class MediaPlaybackController {
    private var didSendPause = false

    // MARK: - Constants

    /// NX_KEYTYPE_PLAY — the system play/pause media key
    private static let mediaPlayPauseKeyCode: Int32 = 16
    private static let keyDownFlags: UInt32 = 0xA00
    private static let keyUpFlags: UInt32 = 0xB00
    private static let systemDefinedSubtype: Int16 = 8

    func pauseIfNeeded() {
        didSendPause = true
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media pause key")
    }

    func resumeIfNeeded() {
        guard didSendPause else { return }
        didSendPause = false
        Self.sendMediaKeyEvent()
        Logger.audio.info("Sent media resume key")
    }

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
