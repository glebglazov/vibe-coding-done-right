import Foundation
@testable import vcdr_ios

final class FakeKeyboardChannel: KeyboardChannelProtocol, @unchecked Sendable {
    enum Interaction: Equatable {
        case publish(KeyboardWireSnapshot)
        case refresh(KeyboardWireSnapshot)
        case readCommands
        case writeHeartbeat(alive: Bool, now: Date)
        case isAppLikelyAlive(now: Date)
    }

    private let lock = NSLock()
    private let heartbeatFreshnessWindow: TimeInterval
    private var commands: [KeyboardCommand] = []
    private var heartbeat: Date?
    private var recordedInteractions: [Interaction] = []

    init(heartbeatFreshnessWindow: TimeInterval = KeyboardChannel.heartbeatFreshnessWindow) {
        self.heartbeatFreshnessWindow = heartbeatFreshnessWindow
    }

    var interactions: [Interaction] {
        lock.withLock { recordedInteractions }
    }

    /// Every snapshot published with a Darwin post, in order.
    var published: [KeyboardWireSnapshot] {
        interactions.compactMap {
            guard case .publish(let snapshot) = $0 else { return nil }
            return snapshot
        }
    }

    /// The run phase of each published snapshot: what the keyboard renders.
    var phases: [KeyboardWirePhase?] {
        published.map { $0.run?.phase }
    }

    func enqueue(_ command: KeyboardCommand) {
        lock.withLock { commands.append(command) }
    }

    func publish(_ snapshot: KeyboardWireSnapshot) {
        record(.publish(snapshot))
    }

    func refresh(_ snapshot: KeyboardWireSnapshot) {
        record(.refresh(snapshot))
    }

    func readCommands() -> [KeyboardCommand] {
        lock.withLock {
            recordedInteractions.append(.readCommands)
            return commands
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

    private func record(_ interaction: Interaction) {
        lock.withLock {
            recordedInteractions.append(interaction)
        }
    }
}

extension KeyboardChannel {
    /// The run phase the keyboard reads from the wire.
    func readPhase() -> KeyboardWirePhase? {
        readSnapshot()?.run?.phase
    }
}
