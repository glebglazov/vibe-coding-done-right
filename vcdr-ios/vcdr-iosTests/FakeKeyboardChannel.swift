import Foundation
@testable import vcdr_ios

final class FakeKeyboardChannel: KeyboardChannelProtocol, @unchecked Sendable {
    enum Interaction: Equatable {
        case publish(KeyboardChannel.RecordingState)
        case publishBundledResult(String)
        case publishFailure(String)
        case readAndClearCommand
        case clearCommand
        case writeHeartbeat(alive: Bool, now: Date)
        case isAppLikelyAlive(now: Date)
        case isCancelStampFresh(now: Date)
    }

    private let lock = NSLock()
    private let heartbeatFreshnessWindow: TimeInterval
    private var command: KeyboardChannel.Command?
    private var heartbeat: Date?
    /// Controls `isCancelStampFresh(now:)`. `nil` (the default) reports no
    /// queued cancel — tests that exercise a Discard set it explicitly to
    /// simulate a fresh or stale stamp.
    private var cancelStampFresh: Bool?
    private var recordedInteractions: [Interaction] = []

    init(heartbeatFreshnessWindow: TimeInterval = KeyboardChannel.heartbeatFreshnessWindow) {
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

    func publishFailure(reason: String) {
        record(.publishFailure(reason))
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
