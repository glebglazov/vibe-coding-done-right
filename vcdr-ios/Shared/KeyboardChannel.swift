import Foundation

nonisolated protocol KeyboardChannelProtocol: Sendable {
    func publish(_ state: KeyboardChannel.RecordingState)
    func publishBundledResult(_ text: String)
    func publishFailure(reason: String)
    func readAndClearCommand() -> KeyboardChannel.Command?
    func clearCommand()
    func writeHeartbeat(alive: Bool, now: Date)
    func isAppLikelyAlive(now: Date) -> Bool
    func isCancelStampFresh(now: Date) -> Bool
}

nonisolated extension KeyboardChannelProtocol {
    func writeHeartbeat(alive: Bool) {
        writeHeartbeat(alive: alive, now: Date())
    }

    func isAppLikelyAlive() -> Bool {
        isAppLikelyAlive(now: Date())
    }

    func isCancelStampFresh() -> Bool {
        isCancelStampFresh(now: Date())
    }
}

nonisolated struct KeyboardChannel: KeyboardChannelProtocol, @unchecked Sendable {
    enum Command: String, Equatable {
        case startRecording
        case stopRecording
        /// Ends the run without producing text (Discard, ADR-0003). Written
        /// together with a wall-clock stamp in `Keys.commandCancelStamp` —
        /// unlike the other two commands, applying it is conditional on that
        /// stamp still being fresh.
        case cancelRecording
    }

    /// The wire vocabulary: one token per value the app can write to the state
    /// key. Every Recording Run terminal state has its own token, so the
    /// keyboard never has to infer which one happened (ADR-0004).
    ///
    /// Two tokens carry a payload appended after `|` — `idle` carries the
    /// Bundled Result and `failed` carries the failure reason. Publish those
    /// through `publishBundledResult` / `publishFailure(reason:)` rather than
    /// `publish`, so the payload always travels with its token.
    enum RecordingState: String, Equatable {
        case idle
        case recording
        case transcribing
        case emptyResult
        case cancelled
        case failed
    }

    /// A decoded wire value: a token plus its payload, if it had one.
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case emptyResult
        case cancelled
        /// Processing Failure, carrying the same reason string the app shows.
        case failed(String)
        case bundledResult(String)
    }

    enum Action: Equatable {
        case commandSent
        case openURL(URL)
    }

    private enum Keys {
        static let command = "command"
        static let commandCancelStamp = "command_cancel_stamp"
        static let state = "recordingState"
        static let heartbeat = "app_heartbeat_at"
    }

    private let defaults: UserDefaults
    private let notify: @Sendable (String) -> Void
    private let heartbeatFreshnessWindow: TimeInterval
    private let cancelFreshnessWindow: TimeInterval

    /// How long a Heartbeat stays credible — the window over which the app is
    /// treated as reachable in place. The keyboard reads it to choose between a
    /// Darwin command and the Deep-Link Fallback, and Mic Presence rides the
    /// same window as its stale horizon, so the lock-screen card and the
    /// keyboard cannot disagree about In-Place Reachability (ADR-0006). Three
    /// times the app's 5s heartbeat cadence: wide enough to survive a missed
    /// beat, narrow enough that a dead app is noticed quickly.
    static let heartbeatFreshnessWindow: TimeInterval = 18

    static let appGroupID = "group.glebglazov.vcdr-ios"
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!
    static let stopDeepLinkURL = URL(string: "vcdr-ios://stop")!
    static let failureDeepLinkURL = URL(string: "vcdr-ios://failure")!
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
        heartbeatFreshnessWindow: TimeInterval = KeyboardChannel.heartbeatFreshnessWindow,
        cancelFreshnessWindow: TimeInterval = 10
    ) {
        self.defaults = defaults
        self.notify = notify
        self.heartbeatFreshnessWindow = heartbeatFreshnessWindow
        self.cancelFreshnessWindow = cancelFreshnessWindow
    }

    // MARK: - Keyboard-side commands

    @discardableResult
    func startRecording(now: Date = Date()) -> Action {
        if isAppLikelyAlive(now: now) {
            send(.startRecording)
            return .commandSent
        }
        return .openURL(Self.recordDeepLinkURL)
    }

    @discardableResult
    func stopRecording(now: Date = Date()) -> Action {
        if isAppLikelyAlive(now: now) {
            send(.stopRecording)
            return .commandSent
        }
        return .openURL(Self.stopDeepLinkURL)
    }

    /// Ends the active Recording Run without producing text (Discard,
    /// ADR-0003). Unlike `startRecording`/`stopRecording` this never falls
    /// back to a deep link — foregrounding the app to throw something away
    /// defeats the point — so it does not return an `Action` for the caller
    /// to branch on. The wall-clock stamp lets the app drop a cancel that sat
    /// queued across a suspend instead of applying it to whatever run is
    /// active when the app next wakes.
    func cancelRecording(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Keys.commandCancelStamp)
        send(.cancelRecording)
    }

    func send(_ command: Command) {
        defaults.set(command.rawValue, forKey: Keys.command)
        defaults.synchronize()
        notify(Self.commandNotificationName)
    }

    func readAndClearCommand() -> Command? {
        guard
            let raw = defaults.string(forKey: Keys.command),
            let command = Command(rawValue: raw)
        else { return nil }
        defaults.removeObject(forKey: Keys.command)
        return command
    }

    func clearCommand() {
        defaults.removeObject(forKey: Keys.command)
    }

    // MARK: - State

    func readState() -> State {
        guard let raw = defaults.string(forKey: Keys.state) else { return .idle }
        return Self.decodeState(raw)
    }

    func publish(_ state: RecordingState) {
        publishRaw(state.rawValue)
    }

    func publishBundledResult(_ text: String) {
        publishRaw(Self.encodeBundledResult(text))
    }

    /// Publishes a Processing Failure together with the reason the app shows
    /// the user, so the keyboard's FAILED pill and the app's error text come
    /// from one fact rather than two.
    func publishFailure(reason: String) {
        publishRaw(Self.encodeFailure(reason: reason))
    }

    func publishEmptyResult() {
        publish(.emptyResult)
    }

    func clearResult() {
        publish(.idle)
    }

    /// Returns the channel to idle without a Darwin post — for the keyboard
    /// clearing a terminal state it has just rendered. The keyboard is the only
    /// reader of this key, so the post would come straight back to it and cut
    /// the flash it is in the middle of showing; the app never observes state.
    func consumeState() {
        defaults.set(RecordingState.idle.rawValue, forKey: Keys.state)
        defaults.synchronize()
    }

    private func publishRaw(_ value: String) {
        defaults.set(value, forKey: Keys.state)
        defaults.synchronize()
        notify(Self.stateNotificationName)
    }

    static func decodeState(_ raw: String) -> State {
        if let text = payload(of: .idle, in: raw) {
            return text.isEmpty ? .idle : .bundledResult(text)
        }
        if let reason = payload(of: .failed, in: raw) {
            return .failed(reason)
        }
        guard let state = RecordingState(rawValue: raw) else { return .idle }
        switch state {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .emptyResult: return .emptyResult
        case .cancelled: return .cancelled
        case .failed: return .failed("")
        }
    }

    static func encodeBundledResult(_ text: String) -> String {
        encode(.idle, payload: text)
    }

    static func encodeFailure(reason: String) -> String {
        encode(.failed, payload: reason)
    }

    private static func encode(_ state: RecordingState, payload: String) -> String {
        "\(state.rawValue)|\(payload)"
    }

    /// The payload written after `<token>|`, or nil when `raw` is not that
    /// token's payload form. Only the first separator is significant, so a
    /// payload containing `|` survives the roundtrip.
    private static func payload(of state: RecordingState, in raw: String) -> String? {
        let prefix = "\(state.rawValue)|"
        guard raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
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

    // MARK: - Cancel freshness

    /// True when a queued `cancelRecording` command's stamp is still inside
    /// the freshness window. Always clears the stamp, so a stale cancel that
    /// sat in the app group across a suspend is dropped for good rather than
    /// being re-evaluated against whatever Recording Run is active next.
    func isCancelStampFresh(now: Date = Date()) -> Bool {
        let stamp = defaults.double(forKey: Keys.commandCancelStamp)
        defaults.removeObject(forKey: Keys.commandCancelStamp)
        guard stamp > 0 else { return false }
        return now.timeIntervalSince1970 - stamp < cancelFreshnessWindow
    }
}
