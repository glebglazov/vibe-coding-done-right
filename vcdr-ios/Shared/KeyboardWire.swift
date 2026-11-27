import Foundation

/// One Recording Run's identity. A late event names the run it was made for,
/// so it can be dropped when that run is no longer the one it would act on.
nonisolated struct RunID: Hashable, Sendable, Codable {
    let raw: UUID

    init(raw: UUID = UUID()) {
        self.raw = raw
    }
}

/// One keyboard tap's identity. The app acknowledges a command by its ID, so
/// the keyboard can tell its own command from whatever run is on the wire.
nonisolated struct CommandID: Hashable, Sendable, Codable {
    let raw: UUID

    init(raw: UUID = UUID()) {
        self.raw = raw
    }
}

/// What the app publishes on the Keyboard Channel. Written only by the app,
/// one JSON value in one key.
nonisolated struct KeyboardWireSnapshot: Codable, Equatable, Sendable {
    /// New for each app process. `seq` counts within one process only.
    let appSession: UUID
    /// Grows by one with each change the app publishes.
    let seq: UInt64
    /// The newest run of this process, nil before its first run.
    let run: KeyboardWireRun?
    /// The commands the app took, newest last: the Command Acknowledgement.
    let handledCommands: [CommandID]
    /// Renewed while a run is in progress, so a snapshot from an app that
    /// stopped running can be told apart from one that is still true.
    let writtenAt: Date

    func acknowledges(_ command: CommandID) -> Bool {
        handledCommands.contains(command)
    }
}

nonisolated struct KeyboardWireRun: Codable, Equatable, Sendable {
    let id: RunID
    let phase: KeyboardWirePhase
}

nonisolated enum KeyboardWirePhase: Codable, Equatable, Sendable {
    /// Arming or Capturing.
    case recording
    /// Finalizing.
    case transcribing
    /// The run ended and its outcome is for another surface (an app or a
    /// Shortcut run): the keyboard has nothing to show for it.
    case idle
    /// The run ended with an outcome for the keyboard (ADR-0004).
    case ended(KeyboardWireOutcome)

    var isInProgress: Bool {
        switch self {
        case .recording, .transcribing: true
        case .idle, .ended: false
        }
    }
}

nonisolated enum KeyboardWireOutcome: Codable, Equatable, Sendable {
    /// The Bundled Result.
    case text(String)
    case emptyResult
    case cancelled
    /// Processing Failure, with the same reason the app shows.
    case failed(reason: String)
}

/// A command from the keyboard. Written only by the keyboard, as a list that
/// it trims by age.
nonisolated struct KeyboardCommand: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case start
        /// Stop names the run the keyboard showed, so it cannot stop another.
        case stop(RunID)
        /// Discard names its run too, and applies only while fresh (ADR-0003).
        case discard(RunID)
    }

    let id: CommandID
    let kind: Kind
    let sentAt: Date
}

/// A Deep-Link Fallback URL. It carries the command it stands in for, so the
/// app takes a command only once, by whichever path arrives first.
nonisolated enum KeyboardDeepLink: Equatable, Sendable {
    case record(CommandID)
    case stop(CommandID, run: RunID)
    /// Opens the app on the Processing Failure reason. A route only.
    case failure

    private static let scheme = "vcdr-ios"
    private static let commandItem = "cmd"
    private static let runItem = "run"

    /// Nil for a URL that is not a complete VCDR deep link.
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        func uuid(_ name: String) -> UUID? {
            components.queryItems?.first { $0.name == name }?.value.flatMap(UUID.init(uuidString:))
        }
        switch url.host {
        case "record":
            guard let command = uuid(Self.commandItem) else { return nil }
            self = .record(CommandID(raw: command))
        case "stop":
            guard let command = uuid(Self.commandItem), let run = uuid(Self.runItem) else { return nil }
            self = .stop(CommandID(raw: command), run: RunID(raw: run))
        case "failure":
            self = .failure
        default:
            return nil
        }
    }

    /// Nil only if Foundation refuses a scheme, host and UUID query values.
    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .record(let command):
            components.host = "record"
            components.queryItems = [URLQueryItem(name: Self.commandItem, value: command.raw.uuidString)]
        case .stop(let command, let run):
            components.host = "stop"
            components.queryItems = [
                URLQueryItem(name: Self.commandItem, value: command.raw.uuidString),
                URLQueryItem(name: Self.runItem, value: run.raw.uuidString)
            ]
        case .failure:
            components.host = "failure"
        }
        return components.url
    }
}
