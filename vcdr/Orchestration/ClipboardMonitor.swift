import AppKit
import OSLog

/// Monitors clipboard changes during recording to capture additional text selections.
/// Starts polling after an initial grace period (to let SelectionCapturer finish its
/// clipboard save-copy-restore cycle), then watches for real user Cmd+C events.
actor ClipboardMonitor {
    // MARK: - Constants

    /// Delay before starting to poll. SelectionCapturer's worst case (Layer 3 Cmd+C)
    /// takes ~400ms for its clipboard save-copy-restore cycle.
    private static let initialGracePeriod: Duration = .milliseconds(500)
    /// How often to check NSPasteboard.general.changeCount.
    private static let pollInterval: Duration = .milliseconds(250)

    private var pollingTask: Task<Void, Never>?
    private var captures: [String] = []

    /// Starts monitoring clipboard changes. Calls `onCapture` on each new capture.
    /// The callback receives the captured text.
    ///
    /// - Parameter baselineChangeCount: If provided, the monitor ignores any clipboard
    ///   changes until `changeCount` exceeds this value. Use the pasteboard's `changeCount`
    ///   captured **before** SelectionCapturer runs so its internal clipboard manipulation
    ///   (copy → read → restore) is ignored regardless of timing.
    func start(baselineChangeCount: Int? = nil, onCapture: @MainActor @Sendable @escaping (String) -> Void) {
        stop()

        pollingTask = Task { [weak self] in
            // Grace period: let SelectionCapturer finish its clipboard manipulation
            try? await Task.sleep(for: Self.initialGracePeriod)
            guard !Task.isCancelled else { return }

            // Use the provided baseline or snapshot after the grace period.
            // SelectionCapturer's clipboard cycle (copy → read → restore) produces
            // multiple changeCount bumps. By anchoring to the pre-capture count,
            // we skip all of them regardless of timing.
            let pasteboard = NSPasteboard.general
            var lastChangeCount = baselineChangeCount ?? pasteboard.changeCount
            var lastContent: String? = nil
            // Fast-forward: if the pasteboard has already moved past baseline,
            // record its current content so we don't re-fire for stale changes.
            if pasteboard.changeCount != lastChangeCount {
                lastChangeCount = pasteboard.changeCount
                lastContent = pasteboard.string(forType: .string)
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }

                let currentChangeCount = pasteboard.changeCount
                guard currentChangeCount != lastChangeCount else { continue }
                lastChangeCount = currentChangeCount

                guard let newContent = pasteboard.string(forType: .string),
                      !newContent.isEmpty,
                      newContent != lastContent else { continue }

                // Deduplicate against the last captured text
                let lastCapture = await self?.captures.last
                guard newContent != lastCapture else { continue }

                lastContent = newContent
                await self?.appendCapture(newContent)
                Logger.recording.info("Clipboard capture: \(newContent.count) chars")

                await onCapture(newContent)
            }
        }
    }

    /// Stops monitoring and returns all captured texts.
    @discardableResult
    func stop() -> [String] {
        pollingTask?.cancel()
        pollingTask = nil
        let result = captures
        captures = []
        return result
    }

    private func appendCapture(_ text: String) {
        captures.append(text)
    }
}
