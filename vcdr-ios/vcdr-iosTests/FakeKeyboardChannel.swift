import Foundation
@testable import vcdr_ios

final class FakeKeyboardChannel: KeyboardChannelProtocol, @unchecked Sendable {
    enum Interaction: Equatable {
        case publish(KeyboardChannel.RecordingState)
        case publishBundledResult(String)
        case readAndClearCommand
        case clearCommand
        case readCaptures
        case replaceCaptures([String])
        case clearCaptures
        case clearLegacySelectedText
        case writeHeartbeat(alive: Bool, now: Date)
        case isAppLikelyAlive(now: Date)
        case isCancelStampFresh(now: Date)
    }

    private let lock = NSLock()
    private let heartbeatFreshnessWindow: TimeInterval
    private var command: KeyboardChannel.Command?
    private var captures: [String] = []
    private var heartbeat: Date?
    /// Controls `isCancelStampFresh(now:)`. `nil` (the default) reports no
    /// queued cancel — tests that exercise a Discard set it explicitly to
    /// simulate a fresh or stale stamp.
    private var cancelStampFresh: Bool?
    private var recordedInteractions: [Interaction] = []

    init(heartbeatFreshnessWindow: TimeInterval = 18) {
        self.heartbeatFreshnessWindow = heartbeatFreshnessWindow
    }

    func enqueueCancel(fresh: Bool) {
        lock.withLock {
            self.command = .cancelRecording
            self.cancelStampFresh = fresh
        }
    }

    var interactions: [Interaction] {
        lock.withLock { recordedInteractions }
    }

    func enqueue(_ command: KeyboardChannel.Command) {
        lock.withLock {
            self.command = command
        }
    }

    func publish(_ state: KeyboardChannel.RecordingState) {
        record(.publish(state))
    }

    func publishBundledResult(_ text: String) {
        record(.publishBundledResult(text))
    }

    func readAndClearCommand() -> KeyboardChannel.Command? {
        lock.withLock {
            recordedInteractions.append(.readAndClearCommand)
            defer { command = nil }
            return command
        }
    }

    func clearCommand() {
        lock.withLock {
            recordedInteractions.append(.clearCommand)
            command = nil
        }
    }

    func readCaptures() -> [String] {
        lock.withLock {
            recordedInteractions.append(.readCaptures)
            return captures
        }
    }

    func replaceCaptures(_ captures: [String]) {
        lock.withLock {
            recordedInteractions.append(.replaceCaptures(captures))
            self.captures = captures
        }
    }

    func clearCaptures() {
        lock.withLock {
            recordedInteractions.append(.clearCaptures)
            captures = []
        }
    }

    func clearLegacySelectedText() {
        record(.clearLegacySelectedText)
    }

    func writeHeartbeat(alive: Bool, now: Date) {
        lock.withLock {
            recordedInteractions.append(.writeHeartbeat(alive: alive, now: now))
            heartbeat = alive ? now : nil
        }
    }

    func isAppLikelyAlive(now: Date) -> Bool {
        lock.withLock {
            recordedInteractions.append(.isAppLikelyAlive(now: now))
            guard let heartbeat else { return false }
            return now.timeIntervalSince(heartbeat) < heartbeatFreshnessWindow
        }
    }

    func isCancelStampFresh(now: Date) -> Bool {
        lock.withLock {
            recordedInteractions.append(.isCancelStampFresh(now: now))
            defer { cancelStampFresh = nil }
            return cancelStampFresh ?? false
        }
    }

    private func record(_ interaction: Interaction) {
        lock.withLock {
            recordedInteractions.append(interaction)
        }
    }
}
