import Foundation

/// What the keyboard shows. Every case but `idle` names its run, so a
/// snapshot for another run is never mistaken for this one.
nonisolated enum KeyboardShown: Equatable, Sendable {
    case idle
    case recording(RunID)
    case transcribing(RunID)
    /// The Bundled Result, waiting for a tap to insert it.
    case ready(RunID, text: String)
    /// A terminal pill. It shows for a while, then idle comes back.
    case flash(RunID, KeyboardFlash)
}

nonisolated enum KeyboardFlash: Equatable, Sendable {
    case emptyResult
    case cancelled
    case failed
}

/// One step of the keyboard's stop poll, from one read of the wire.
nonisolated enum KeyboardStopStep: Equatable, Sendable {
    case wait
    /// The Bundled Result arrived: insert it while the tap's event context lasts.
    case insert(String)
    /// The run ended without text, or the wire shows another run: render it.
    case render
    /// The app did not take the stop in time: open the stop deep link.
    case openDeepLink
}

/// The keyboard's reading of the Keyboard Channel: what to show for the
/// app's snapshot, whether the app took a command, and which run's outcome
/// the keyboard already showed. The keyboard never writes the app's
/// snapshot, so nothing it reads can be taken away from another read.
nonisolated struct KeyboardWireReader {
    private let channel: KeyboardChannel
    private(set) var shown: KeyboardShown = .idle
    /// The newest snapshot read. A read that returns an older one (the
    /// defaults of two processes can lag) is not rendered.
    private var lastRead: KeyboardWireSnapshot?

    init(channel: KeyboardChannel) {
        self.channel = channel
    }

    /// The Command Acknowledgement: the app took `command`, whatever its run
    /// did next. A run that ended at once still acknowledges its start.
    func isAcknowledged(_ command: CommandID) -> Bool {
        channel.readSnapshot()?.acknowledges(command) ?? false
    }

    /// Reads the wire and returns what to show. A pill that starts settles
    /// its run, so a later appearance does not show it again.
    mutating func refresh(now: Date = Date()) -> KeyboardShown {
        let snapshot = channel.readSnapshot()
        if let snapshot, let lastRead, snapshot.isOlder(than: lastRead) { return shown }
        lastRead = snapshot ?? lastRead
        let next = Self.shown(
            for: snapshot,
            over: shown,
            settledRun: channel.settledRun(),
            appReachable: channel.isAppLikelyAlive(now: now),
            now: now
        )
        if case .flash(let run, _) = next, next != shown {
            channel.markSettled(run)
        }
        shown = next
        return shown
    }

    /// The pill for `run` has had its time. A pill for a newer run stays.
    mutating func endFlash(of run: RunID, now: Date = Date()) -> KeyboardShown {
        guard case .flash(run, _) = shown else { return shown }
        shown = .idle
        return refresh(now: now)
    }

    /// The Bundled Result of `run` is in the text field.
    mutating func didInsert(for run: RunID, now: Date = Date()) -> KeyboardShown {
        channel.markSettled(run)
        shown = .idle
        return refresh(now: now)
    }

    /// One poll step after the keyboard sent `command` to stop `run`.
    func stopStep(for command: CommandID, of run: RunID, ackTimedOut: Bool) -> KeyboardStopStep {
        guard let snapshot = channel.readSnapshot(), let wireRun = snapshot.run, wireRun.id == run else {
            return .render
        }
        switch wireRun.phase {
        case .ended(.text(let text)) where channel.settledRun() != run:
            return .insert(text)
        case .ended, .idle:
            return .render
        case .transcribing:
            return .wait
        case .recording:
            return snapshot.acknowledges(command) || !ackTimedOut ? .wait : .openDeepLink
        }
    }

    /// What to show for `snapshot` while `current` is on screen.
    ///
    /// - A pill stays until its time is up, unless the wire shows another run.
    /// - A run in progress shows only while the app can still move it: its
    ///   Heartbeat is fresh, or the app renewed the snapshot recently. The
    ///   Heartbeat alone is not enough, because a Hot-Session Timeout of
    ///   Never clears it while Finalizing still runs.
    /// - An outcome shows once per run.
    static func shown(
        for snapshot: KeyboardWireSnapshot?,
        over current: KeyboardShown,
        settledRun: RunID?,
        appReachable: Bool,
        now: Date
    ) -> KeyboardShown {
        guard let snapshot, let run = snapshot.run else { return keepingFlash(current, else: .idle) }
        if case .flash(run.id, _) = current { return current }

        switch run.phase {
        case .idle:
            return .idle
        case .recording, .transcribing:
            let renewed = now.timeIntervalSince(snapshot.writtenAt) < KeyboardChannel.heartbeatFreshnessWindow
            guard appReachable || renewed else { return .idle }
            return run.phase == .recording ? .recording(run.id) : .transcribing(run.id)
        case .ended(let outcome):
            guard settledRun != run.id else { return .idle }
            switch outcome {
            case .text(let text): return .ready(run.id, text: text)
            case .emptyResult: return .flash(run.id, .emptyResult)
            case .cancelled: return .flash(run.id, .cancelled)
            // The reason stays in the app; the pill only says a failure
            // happened (ADR-0004).
            case .failed: return .flash(run.id, .failed)
            }
        }
    }

    private static func keepingFlash(_ current: KeyboardShown, else other: KeyboardShown) -> KeyboardShown {
        if case .flash = current { return current }
        return other
    }
}

private extension KeyboardWireSnapshot {
    func isOlder(than other: KeyboardWireSnapshot) -> Bool {
        appSession == other.appSession && seq < other.seq
    }
}
