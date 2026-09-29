import AppKit
import OSLog

actor ClipboardMonitor {
    // MARK: - Constants

    /// How often to check the monitored pasteboard's changeCount.
    private static let pollInterval: Duration = .milliseconds(250)

    private enum Phase {
        case idle
        case monitoring(Task<Void, Never>)
        case stopped
    }

    private let pasteboardName: String
    private var phase: Phase = .idle

    init(pasteboardName: String = NSPasteboard.Name.general.rawValue) {
        self.pasteboardName = pasteboardName
    }

    // A run that ends without a stop, such as "No audio recorded", drops its monitor here.
    deinit {
        if case .monitoring(let pollingTask) = phase {
            pollingTask.cancel()
        }
    }

    /// Starts monitoring clipboard changes. Calls `onCapture` on each new capture.
    /// The callback receives the captured text.
    ///
    /// - Parameter baselineChangeCount: If provided, the monitor starts from this
    ///   changeCount value. Pass the pasteboard's `changeCount` captured **after**
    ///   any clipboard-manipulating operations (e.g. SelectionCapturer) have finished.
    func start(baselineChangeCount: Int? = nil, onCapture: @MainActor @Sendable @escaping (String) -> Void) {
        guard case .idle = phase else { return }

        let pasteboardName = self.pasteboardName
        phase = .monitoring(Task<Void, Never> {
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

                await MainActor.run {
                    Logger.recording.info("ClipboardMonitor: captured \(newContent.count) chars: \"\(newContent.prefix(80))\"")
                }

                await onCapture(newContent)
            }
        })
    }

    func stop() {
        if case .monitoring(let pollingTask) = phase {
            pollingTask.cancel()
        }
        phase = .stopped
    }
}
