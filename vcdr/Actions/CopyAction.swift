import AppKit

struct CopyAction: PostTranscriptionAction {
    let name = "Copy"

    func execute(text: String) async throws -> String? {
        ClipboardHelper.writeString(text)
        return nil
    }
}
