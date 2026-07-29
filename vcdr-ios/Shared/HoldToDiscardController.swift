import Foundation

/// Drives the hold-Stop-to-Discard interaction: progress from touch-down,
/// normal Stop on early release, Discard at the hold threshold without
/// waiting for release.
@MainActor
@Observable
final class HoldToDiscardController {
    // MARK: - Constants

    static let holdDuration: TimeInterval = 2
    static let cancelledFlashDuration: TimeInterval = 1
    static let progressTick: Duration = .milliseconds(16)

    // MARK: - State

    var isHolding = false
    var progress: CGFloat = 0

    private var holdStart: Date?
    private var discardTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var didDiscard = false

    private let onStop: () -> Void
    private let onDiscard: () -> Void
    private let onDiscardHaptic: () -> Void

    init(
        onStop: @escaping () -> Void,
        onDiscard: @escaping () -> Void,
        onDiscardHaptic: @escaping () -> Void = {}
    ) {
        self.onStop = onStop
        self.onDiscard = onDiscard
        self.onDiscardHaptic = onDiscardHaptic
    }

    func touchDown() {
        guard !isHolding else { return }
        didDiscard = false
        isHolding = true
        progress = 0
        holdStart = Date()

        discardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.holdDuration))
            guard !Task.isCancelled, let self else { return }
            self.fireDiscard()
        }

        progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.tickProgress()
                if self.progress >= 1 { break }
                try? await Task.sleep(for: Self.progressTick)
            }
        }
    }

    func touchUp() {
        discardTask?.cancel()
        discardTask = nil
        progressTask?.cancel()
        progressTask = nil
        isHolding = false
        progress = 0
        holdStart = nil

        if !didDiscard {
            onStop()
        }
        didDiscard = false
    }

    private func tickProgress() {
        guard let holdStart else { return }
        let elapsed = Date().timeIntervalSince(holdStart)
        progress = min(1, CGFloat(elapsed / Self.holdDuration))
    }

    private func fireDiscard() {
        guard !didDiscard else { return }
        didDiscard = true
        isHolding = false
        progress = 1
        progressTask?.cancel()
        progressTask = nil
        onDiscardHaptic()
        onDiscard()
    }
}
