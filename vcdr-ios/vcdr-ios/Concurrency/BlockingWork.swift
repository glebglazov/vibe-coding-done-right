import Foundation

/// Runs a blocking, synchronous `body` on a GCD global queue instead of Swift's
/// cooperative thread pool, handing its result back to the awaiting task.
///
/// `Task.detached` schedules onto the global *cooperative* executor, whose width
/// is capped near the core count and which the concurrency runtime assumes tasks
/// only ever *suspend* on — never block. A synchronous system call that blocks
/// for seconds (CoreML `MLModel(contentsOf:)` ANE specialization, `AVAudioEngine`
/// input-node init, `AVAudioSession.setActive`) holds one of those scarce threads
/// for its whole duration. Hold enough of them and no thread is left to service
/// waiting actors: the main-actor init poll stalls and gestures time out — the
/// exact App Shell freeze observed on cold-launch traces. GCD's global queues
/// spin up additional threads for blocking work, so offloading here keeps the
/// cooperative pool — and the main actor — free.
///
/// Use `withThrowingBlockingTask` when `body` can throw.
func withBlockingTask<T>(
    qos: DispatchQoS.QoSClass,
    _ body: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(returning: body())
        }
    }
}

/// Throwing counterpart to `withBlockingTask`. See its documentation for why
/// blocking work must stay off the cooperative pool.
func withThrowingBlockingTask<T>(
    qos: DispatchQoS.QoSClass,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

extension DispatchQoS.QoSClass {
    /// Maps a `TaskPriority` to the closest GCD QoS class so blocking work
    /// offloaded via `withBlockingTask` keeps the priority its caller intended
    /// — automatic launch work runs at `.utility`, a user-driven Recording Run
    /// at `.userInitiated`.
    init(_ priority: TaskPriority) {
        switch priority.rawValue {
        case TaskPriority.high.rawValue: self = .userInitiated
        case TaskPriority.utility.rawValue: self = .utility
        case TaskPriority.background.rawValue: self = .background
        default: self = .default
        }
    }
}
