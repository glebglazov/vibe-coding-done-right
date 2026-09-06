import Foundation

/// Whether anything is waiting on a preparation while it runs. A recording
/// already under way is waiting on its model: the audio is held until that
/// model loads. Warming the Default at launch, or installing one someone just
/// named on a screen, is not — nobody is standing in front of it.
enum PreparationUrgency {
    case awaited
    case unawaited
}

/// Lets one Transcription Model prepare at a time. Two preparing together want
/// the same neural engine and both finish later than either would alone: a
/// Whisper load that takes 34s on its own was measured at nearly two minutes
/// beside Parakeet's compile. Order is by what is waiting rather than by who
/// asked first, so the model a recording is held up by never queues behind one
/// nobody is waiting on.
actor ModelPreparationQueue {

    /// Runs `preparation` once the queue is free. `whileHeldBack` is called
    /// first, and only when there is something to wait for — a preparation that
    /// starts at once has no wait to announce.
    func takingTurn(
        urgency: PreparationUrgency,
        whileHeldBack: @Sendable () async -> Void,
        _ preparation: @Sendable () async throws -> Void
    ) async rethrows {
        if isPreparing {
            await whileHeldBack()
            await waitForTurn(urgency: urgency)
        } else {
            isPreparing = true
        }
        // Handed on however the preparation ended: one that gives up must not
        // take the models queued behind it down with it.
        defer { handOnTurn() }
        try await preparation()
    }

    private var isPreparing = false
    private var heldBack: [(urgency: PreparationUrgency, resume: CheckedContinuation<Void, Never>)] = []

    private func waitForTurn(urgency: PreparationUrgency) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = (urgency, continuation)
            // An awaited preparation goes in front of every unawaited one and
            // behind the awaited ones already held back: overtaking is about
            // what is waiting on a model, not about who asked last.
            guard urgency == .awaited,
                  let firstUnawaited = heldBack.firstIndex(where: { $0.urgency == .unawaited })
            else {
                heldBack.append(waiter)
                return
            }
            heldBack.insert(waiter, at: firstUnawaited)
        }
    }

    /// Gives the turn to the model at the front, or opens the queue when none
    /// is held back.
    private func handOnTurn() {
        guard !heldBack.isEmpty else {
            isPreparing = false
            return
        }
        heldBack.removeFirst().resume.resume()
    }
}
