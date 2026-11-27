import Foundation

/// The app's side of the Keyboard Channel.
nonisolated protocol KeyboardChannelProtocol: Sendable {
    /// Writes the snapshot and tells the keyboard it changed.
    func publish(_ snapshot: KeyboardWireSnapshot)
    /// Writes the snapshot without telling the keyboard: only `writtenAt`
    /// moved, and waking the keyboard for that would cost it for nothing.
    func refresh(_ snapshot: KeyboardWireSnapshot)
    func readCommands() -> [KeyboardCommand]
    func writeHeartbeat(alive: Bool, now: Date)
    func isAppLikelyAlive(now: Date) -> Bool
}

nonisolated extension KeyboardChannelProtocol {
    func writeHeartbeat(alive: Bool) {
        writeHeartbeat(alive: alive, now: Date())
    }

    func isAppLikelyAlive() -> Bool {
        isAppLikelyAlive(now: Date())
    }
}

/// The Keyboard Channel over the App Group's defaults. Each key has one
/// writer: the snapshot and the Heartbeat are the app's, the command list
/// and the settled run are the keyboard's. So no write can lose another
/// process's write.
nonisolated struct KeyboardChannel: KeyboardChannelProtocol, @unchecked Sendable {
    enum Action: Equatable {
        case commandSent(CommandID)
        case openURL(KeyboardDeepLink)
    }

    private enum Keys {
        static let snapshot = "keyboard_wire_snapshot"
        static let commands = "keyboard_wire_commands"
        static let settledRun = "keyboard_settled_run"
        static let heartbeat = "app_heartbeat_at"
    }

    private let defaults: UserDefaults
    private let notify: @Sendable (String) -> Void
    private let heartbeatFreshnessWindow: TimeInterval

    // MARK: - Constants

    /// How long a Heartbeat stays credible — the window over which the app is
    /// treated as reachable in place. The keyboard reads it to choose between a
    /// Darwin command and the Deep-Link Fallback, and Mic Presence rides the
    /// same window as its stale horizon, so the lock-screen card and the
    /// keyboard cannot disagree about In-Place Reachability (ADR-0006). Three
    /// times the app's 5s heartbeat cadence: wide enough to survive a missed
    /// beat, narrow enough that a dead app is noticed quickly.
    static let heartbeatFreshnessWindow: TimeInterval = 18

    /// How long a Discard stays applicable (ADR-0003). An older one is
    /// dropped, never applied to whatever run is current when the app reads it.
    static let discardFreshnessWindow: TimeInterval = 10

    /// How long a command stays on the list. Longer than the Discard
    /// freshness window, so the app can still read a Discard and drop it.
    static let commandRetention: TimeInterval = 60

    static let appGroupID = "group.glebglazov.vcdr-ios"
    static let commandNotificationName = "glebglazov.vcdr-ios.command"
    static let stateNotificationName = "glebglazov.vcdr-ios.stateChanged"

    static var live: KeyboardChannel {
        KeyboardChannel(
            defaults: UserDefaults(suiteName: appGroupID) ?? .standard,
            notify: DarwinNotificationCenter.post
        )
    }

    init(
        defaults: UserDefaults,
        notify: @escaping @Sendable (String) -> Void = { _ in },
        heartbeatFreshnessWindow: TimeInterval = KeyboardChannel.heartbeatFreshnessWindow
    ) {
        self.defaults = defaults
        self.notify = notify
        self.heartbeatFreshnessWindow = heartbeatFreshnessWindow
    }

    // MARK: - Keyboard side

    /// Sends start as a Darwin command while the Heartbeat is fresh, or
    /// returns the record deep link that carries the same command.
    func startRecording(now: Date = Date()) -> Action {
        let id = CommandID()
        guard isAppLikelyAlive(now: now) else { return .openURL(.record(id)) }
        append(KeyboardCommand(id: id, kind: .start, sentAt: now))
        return .commandSent(id)
    }

    /// Stops `run`, the run the keyboard shows, the same way.
    func stopRecording(_ run: RunID, now: Date = Date()) -> Action {
        let id = CommandID()
        guard isAppLikelyAlive(now: now) else { return .openURL(.stop(id, run: run)) }
        append(KeyboardCommand(id: id, kind: .stop(run), sentAt: now))
        return .commandSent(id)
    }

    /// Discards `run` (ADR-0003). It never falls back to a deep link:
    /// foregrounding the app to throw something away defeats the point. The
    /// app drops a Discard that is no longer fresh when it reads it.
    func discardRecording(_ run: RunID, now: Date = Date()) {
        append(KeyboardCommand(id: CommandID(), kind: .discard(run), sentAt: now))
    }

    /// The app's latest snapshot. Nil before the app first published, or for
    /// a value this build cannot read.
    func readSnapshot() -> KeyboardWireSnapshot? {
        guard let data = defaults.data(forKey: Keys.snapshot) else { return nil }
        return try? JSONDecoder().decode(KeyboardWireSnapshot.self, from: data)
    }

    /// The run whose outcome the keyboard already showed or inserted.
    func settledRun() -> RunID? {
        guard let data = defaults.data(forKey: Keys.settledRun) else { return nil }
        return try? JSONDecoder().decode(RunID.self, from: data)
    }

    func markSettled(_ run: RunID) {
        defaults.set(try? JSONEncoder().encode(run), forKey: Keys.settledRun)
    }

    /// The keyboard is the list's only writer, so this read-and-write loses
    /// no command. A command older than `commandRetention` drops off.
    private func append(_ command: KeyboardCommand) {
        let kept = readCommands().filter {
            command.sentAt.timeIntervalSince($0.sentAt) < Self.commandRetention
        }
        defaults.set(try? JSONEncoder().encode(kept + [command]), forKey: Keys.commands)
        defaults.synchronize()
        notify(Self.commandNotificationName)
    }

    // MARK: - App side

    func publish(_ snapshot: KeyboardWireSnapshot) {
        refresh(snapshot)
        notify(Self.stateNotificationName)
    }

    func refresh(_ snapshot: KeyboardWireSnapshot) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Keys.snapshot)
        defaults.synchronize()
    }

    /// Every command on the list, oldest first.
    func readCommands() -> [KeyboardCommand] {
        defaults.synchronize()
        guard let data = defaults.data(forKey: Keys.commands) else { return [] }
        return (try? JSONDecoder().decode([KeyboardCommand].self, from: data)) ?? []
    }

    // MARK: - Heartbeat

    func writeHeartbeat(alive: Bool, now: Date = Date()) {
        let value = alive ? now.timeIntervalSince1970 : 0
        defaults.set(value, forKey: Keys.heartbeat)
    }

    func isAppLikelyAlive(now: Date = Date()) -> Bool {
        let beat = defaults.double(forKey: Keys.heartbeat)
        guard beat > 0 else { return false }
        return now.timeIntervalSince1970 - beat < heartbeatFreshnessWindow
    }
}
