import OSLog
import UIKit

@MainActor
protocol PasteboardWriting {
    /// Reports whether the pasteboard took the text.
    func write(_ text: String) -> Bool
}

@MainActor
struct GeneralPasteboard: PasteboardWriting {
    func write(_ text: String) -> Bool {
        let pasteboard = UIPasteboard.general
        let changeCount = pasteboard.changeCount
        pasteboard.string = text
        return pasteboard.changeCount != changeCount
    }
}

@MainActor
final class ClipboardRecordingRunCompletionAdapter: RecordingRunCompletionAdapter {
    private let pasteboard: any PasteboardWriting
    private(set) var copied = false

    init(pasteboard: any PasteboardWriting) {
        self.pasteboard = pasteboard
    }

    func complete(_ terminalState: RecordingRunTerminalState) async {
        guard case .success(let success) = terminalState else {
            Logger.recording.info("Clipboard completion: \(terminalState.logName) → nothing copied")
            return
        }
        copied = pasteboard.write(success.finalText)
        if copied {
            Logger.recording.info("Clipboard completion: success → copied (\(success.finalText.count) chars)")
        } else {
            Logger.recording.error(
                "Clipboard completion: success → the pasteboard did not take the text (\(success.finalText.count) chars)"
            )
        }
    }
}
