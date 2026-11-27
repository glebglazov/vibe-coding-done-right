import Foundation
import OSLog

/// The only writer of the app's Keyboard Channel snapshot. A Recording Run
/// reports its phases here by its RunID, and each keyboard command is taken
/// here once, by whichever path brings it first: the Darwin command or the
/// deep link. The main actor orders every write, so a later write always
/// replaces an earlier one on the wire.
@MainActor
final class KeyboardWirePublisher {
    // MARK: - Constants

    /// How many command IDs the snapshot keeps. The keyboard keeps a command
    /// for `KeyboardChannel.commandRetention`, and no one taps this often in
    /// that time.
    private static let handledCommandLimit = 32
    /// How often the snapshot of a run in progress is renewed. The same
    /// cadence as the Heartbeat, well inside the keyboard's freshness window.
    static let renewalInterval: Duration = HotMicSession.heartbeatInterval

    private let channel: any KeyboardChannelProtocol
    private let appSession = UUID()
    /// Commands sent before this process began were for a process that is
    /// gone. They are not taken from the list; a deep link still takes its own.
    private let launchedAt: Date
    private let clock: any HotMicClock
    private let now: () -> Date
    private var seq: UInt64 = 0
    private var run: KeyboardWireRun?
    private var handledCommands: [CommandID] = []
    private var renewal: Task<Void, Never>?

    init(
        channel: any KeyboardChannelProtocol,
        clock: (any HotMicClock)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.channel = channel
        self.clock = clock ?? SystemHotMicClock()
        self.now = now
        self.launchedAt = now()
    }

    isolated deinit {
        renewal?.cancel()
    }

    /// Publishes what this process knows, under its new app session. It
    /// writes no state of its own: a run that began first stays on the wire.
    func publishLaunch() {
        publish()
    }

    /// Shows `phase` for `runID`. The end of a run is absorbing: a second
    /// end, or a late progress, for a run already ended changes nothing.
    func show(_ phase: KeyboardWirePhase, of runID: RunID) {
        if let run, run.id == runID, !run.phase.isInProgress {
            Logger.recording.info("Wire: dropped \(String(describing: phase)) for a run that already ended")
            return
        }
        run = KeyboardWireRun(id: runID, phase: phase)
        publish()
        if phase.isInProgress { startRenewal() } else { stopRenewal() }
    }

    /// The commands not yet taken, in the order the keyboard sent them. Each
    /// is acknowledged before it runs, so a second read cannot take it again.
    func claim(_ commands: [KeyboardCommand]) -> [KeyboardCommand] {
        let unclaimed = commands.filter { !handledCommands.contains($0.id) && $0.sentAt >= launchedAt }
        guard !unclaimed.isEmpty else { return [] }
        acknowledge(unclaimed.map(\.id))
        return unclaimed
    }

    /// True the first time `command` arrives, by either path.
    func claim(_ command: CommandID) -> Bool {
        guard !handledCommands.contains(command) else { return false }
        acknowledge([command])
        return true
    }

    private func acknowledge(_ commands: [CommandID]) {
        handledCommands = Array((handledCommands + commands).suffix(Self.handledCommandLimit))
        publish()
    }

    private func publish() {
        seq += 1
        let snapshot = currentSnapshot()
        Logger.recording.info(
            "Wire snapshot written: seq=\(snapshot.seq) run=\(Self.describe(snapshot.run))"
                + " handled=\(snapshot.handledCommands.count)"
        )
        channel.publish(snapshot)
    }

    private func currentSnapshot() -> KeyboardWireSnapshot {
        KeyboardWireSnapshot(
            appSession: appSession,
            seq: seq,
            run: run,
            handledCommands: handledCommands,
            writtenAt: now()
        )
    }

    /// While a run is in progress the app may be the only one who knows it
    /// is still alive: under a Hot-Session Timeout of Never the Heartbeat is
    /// already cleared during Finalizing.
    private func startRenewal() {
        guard renewal == nil else { return }
        renewal = Task { [weak self, clock] in
            while !Task.isCancelled {
                await clock.sleep(for: Self.renewalInterval)
                guard !Task.isCancelled, let self else { return }
                self.channel.refresh(self.currentSnapshot())
            }
        }
    }

    private func stopRenewal() {
        renewal?.cancel()
        renewal = nil
    }

    /// The Bundled Result is logged by length: the run already logged the text.
    private static func describe(_ run: KeyboardWireRun?) -> String {
        guard let run else { return "none" }
        switch run.phase {
        case .ended(.text(let text)): return "ended(text, \(text.count) chars)"
        default: return String(describing: run.phase)
        }
    }
}
