import OSLog
import UIKit

@MainActor
protocol PasteboardWriting {
    func write(_ text: String)
}

@MainActor
struct GeneralPasteboard: PasteboardWriting {
    func write(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// Clipboard Completion Delivery for a Shortcut run: the same final text the
/// keyboard would get. Every other terminal state writes nothing, so what the
/// user copied before survives an empty or failed run.
@MainActor
final class ClipboardRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let pasteboard: any PasteboardWriting

    init(pasteboard: any PasteboardWriting) {
        self.pasteboard = pasteboard
    }

    func complete(_ terminalState: RecordingRunTerminalState) async {
        guard case .success(let success) = terminalState else {
            Logger.recording.info("Clipboard completion: \(terminalState.logName) → nothing copied")
            return
        }
        Logger.recording.info("Clipboard completion: success → copied (\(success.finalText.count) chars)")
        pasteboard.write(success.finalText)
    }
}
