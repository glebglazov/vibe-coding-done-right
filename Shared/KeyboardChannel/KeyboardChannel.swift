import Foundation

struct KeyboardChannel {
    enum Command: String, Equatable {
        case startRecording
        case stopRecording
    }

    enum RecordingState: String, Equatable {
        case idle
        case recording
        case transcribing
        case emptyResult
    }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case emptyResult
        case bundledResult(String)
    }

    enum Action: Equatable {
        case commandSent
        case openURL(URL)
    }

    private enum Keys {
        static let command = "command"
        static let state = "recordingState"
        static let captures = "shared_captured_texts"
        static let selectedText = "shared_selected_text"
        static let heartbeat = "app_heartbeat_at"
    }

    private let defaults: UserDefaults
    private let notify: (String) -> Void
    private let heartbeatFreshnessWindow: TimeInterval

    static let appGroupID = "group.glebglazov.vcdr-ios"
    static let recordDeepLinkURL = URL(string: "vcdr-ios://record")!
    static let stopDeepLinkURL = URL(string: "vcdr-ios://stop")!
    static let commandNotificationName = "glebglazov.vcdr-ios.command"
    static let stateNotificationName = "glebglazov.vcdr-ios.stateChanged"

    #if os(iOS)
    static var live: KeyboardChannel {
        KeyboardChannel(
            defaults: UserDefaults(suiteName: appGroupID) ?? .standard,
            notify: DarwinNotificationCenter.post
        )
    }
    #endif

    init(
        defaults: UserDefaults,
        notify: @escaping (String) -> Void = { _ in },
        heartbeatFreshnessWindow: TimeInterval = 18
    ) {
        self.defaults = defaults
        self.notify = notify
        self.heartbeatFreshnessWindow = heartbeatFreshnessWindow
    }

    // MARK: - Keyboard-side commands

    @discardableResult
    func startRecording(captures: [String], now: Date = Date()) -> Action {
        replaceCaptures(captures)
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

    func publishEmptyResult() {
        publish(.emptyResult)
    }

    func clearResult() {
        publish(.idle)
    }

    private func publishRaw(_ value: String) {
        defaults.set(value, forKey: Keys.state)
        defaults.synchronize()
        notify(Self.stateNotificationName)
    }

    static func decodeState(_ raw: String) -> State {
        let idlePrefix = "\(RecordingState.idle.rawValue)|"
        if raw.hasPrefix(idlePrefix) {
            let text = String(raw.dropFirst(idlePrefix.count))
            return text.isEmpty ? .idle : .bundledResult(text)
        }
        guard let state = RecordingState(rawValue: raw) else { return .idle }
        switch state {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .emptyResult: return .emptyResult
        }
    }

    static func encodeBundledResult(_ text: String) -> String {
        "\(RecordingState.idle.rawValue)|\(text)"
    }

    // MARK: - Captures

    func readCaptures() -> [String] {
        defaults.synchronize()
        guard let data = defaults.data(forKey: Keys.captures) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func appendCapture(_ text: String) {
        var captures = readCaptures()
        captures.append(text)
        replaceCaptures(captures)
    }

    func replaceCaptures(_ captures: [String]) {
        if let data = try? JSONEncoder().encode(captures) {
            defaults.set(data, forKey: Keys.captures)
        }
        defaults.synchronize()
    }

    func clearCaptures() {
        defaults.removeObject(forKey: Keys.captures)
    }

    func clearLegacySelectedText() {
        defaults.removeObject(forKey: Keys.selectedText)
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
