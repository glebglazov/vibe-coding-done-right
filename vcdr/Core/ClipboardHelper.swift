import AppKit

enum ClipboardHelper {
    /// Writes a string to the general pasteboard, clearing existing contents first.
    static func writeString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
