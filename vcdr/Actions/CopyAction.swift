import AppKit

struct CopyAction: PostTranscriptionAction {
    let name = "Copy"

    func execute(text: String) async throws -> String? {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return nil
    }
}
    