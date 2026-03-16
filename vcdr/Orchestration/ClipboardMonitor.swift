import AppKit
import OSLog

/// Monitors clipboard changes during recording to capture additional text selections.
/// Callers are responsible for starting the monitor only after any clipboard-manipulating
/// operations (e.g. SelectionCapturer) have finished, and passing a fresh baseline.
actor ClipboardMonitor {
    // MARK: - Constants

    /// How often to check NSPasteboard.general.changeCount.
    private static let pollInterval: Duration = .milliseconds(250)

    private var pollingTask: Task<Void, Never>?
    private var captures: [String] = []

    /// Starts monitoring clipboard changes. Calls `onCapture` on each new capture.
    /// The callback receives the captured text.
    ///
    /// - Parameter baselineChangeCount: If provided, the monitor starts from this
    ///   changeCount value. Pass the pasteboard's `changeCount` captured **after**
    ///   any clipboard-manipulating operations (e.g. SelectionCapturer) have finished.
    func start(baselineChangeCount: Int? = nil, onCapture: @MainActor @Sendable @escaping (String) -> Void) {
        stop()

        pollingTask = Task { [weak self] in
            let pasteboard = NSPasteboard.general
            var lastChangeCount = baselineChangeCount ?? pasteboard.changeCount
            var lastContent = pasteboard.string(forType: .string)

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
                Logger.recording.info("ClipboardMonitor: captured \(newContent.count) chars: \"\(newContent.prefix(80))\"")

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
