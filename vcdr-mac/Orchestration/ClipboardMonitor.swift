import AppKit
import OSLog

/// Monitors clipboard changes during recording to capture additional text selections.
/// Callers are responsible for starting the monitor only after any clipboard-manipulating
/// operations (e.g. SelectionCapturer) have finished, and passing a fresh baseline.
actor ClipboardMonitor {
    // MARK: - Constants

    /// How often to check the monitored pasteboard's changeCount.
    private static let pollInterval: Duration = .milliseconds(250)

    private let pasteboardName: String
    private var pollingTask: Task<Void, Never>?
    private var captures: [String] = []

    init(pasteboardName: String = NSPasteboard.Name.general.rawValue) {
        self.pasteboardName = pasteboardName
    }

    /// Starts monitoring clipboard changes. Calls `onCapture` on each new capture.
    /// The callback receives the captured text.
    ///
    /// - Parameter baselineChangeCount: If provided, the monitor starts from this
    ///   changeCount value. Pass the pasteboard's `changeCount` captured **after**
    ///   any clipboard-manipulating operations (e.g. SelectionCapturer) have finished.
    func start(baselineChangeCount: Int? = nil, onCapture: @MainActor @Sendable @escaping (String) -> Void) {
        stop()

        let pasteboardName = self.pasteboardName
        pollingTask = Task<Void, Never> { [weak self] in
            var lastChangeCount: Int
            if let baselineChangeCount {
                lastChangeCount = baselineChangeCount
            } else {
                lastChangeCount = await MainActor.run {
                    NSPasteboard(name: NSPasteboard.Name(pasteboardName)).changeCount
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { break }

                let (currentChangeCount, currentContent) = await MainActor.run {
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
                    return (pasteboard.changeCount, pasteboard.string(forType: .string))
                }
                guard currentChangeCount != lastChangeCount else { continue }
                lastChangeCount = currentChangeCount

                guard let newContent = currentContent,
                      !newContent.isEmpty else { continue }

                await self?.appendCapture(newContent)
                await MainActor.run {
                    Logger.recording.info("ClipboardMonitor: captured \(newContent.count) chars: \"\(newContent.prefix(80))\"")
                }

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
