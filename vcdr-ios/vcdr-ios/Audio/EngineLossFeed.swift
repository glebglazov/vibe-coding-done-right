import Foundation

/// Hands every engine loss to each listener. One `AsyncStream` has only one
/// reader, and both the Hot Mic Session and the coordinator must hear a loss.
@MainActor
final class EngineLossFeed {
    private var continuations: [UUID: AsyncStream<EngineLoss>.Continuation] = [:]

    func stream() -> AsyncStream<EngineLoss> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: EngineLoss.self)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.continuations[id] = nil }
        }
        continuations[id] = continuation
        return stream
    }

    func send(_ loss: EngineLoss) {
        for continuation in continuations.values {
            continuation.yield(loss)
        }
    }
}
