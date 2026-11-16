import Foundation

/// Lets one transcription decode at a time. A run and a discarded recording
/// can both want to decode at once, and two decodes together on the shared
/// CoreML models are unproven. Only the decode takes a turn: a wait for a
/// model to download, or for the Cursor Context read, happens before or after it,
/// so it never holds up the other side.
@MainActor
final class DecodeTurnstile {

    private var isDecoding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Runs `decode` once no other decode is running, in the order of arrival.
    func takingTurn<Result>(_ decode: () async throws -> Result) async rethrows -> Result {
        if isDecoding {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isDecoding = true
        }
        // Handed on however the decode ended, so a failed one does not keep
        // the next one waiting.
        defer { handOnTurn() }
        return try await decode()
    }

    private func handOnTurn() {
        guard !waiting.isEmpty else {
            isDecoding = false
            return
        }
        waiting.removeFirst().resume()
    }
}
