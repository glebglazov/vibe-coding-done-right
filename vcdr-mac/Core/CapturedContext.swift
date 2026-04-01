import Foundation

enum CaptureSource: String, Codable, Sendable {
    /// AX accessibility grab from the frontmost app's selected text
    case selection
    /// Mid-recording or mid-session Cmd+C clipboard capture
    case clipboard
}

struct CapturedContext: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let source: CaptureSource

    init(text: String, source: CaptureSource) {
        self.id = UUID()
        self.text = text
        self.source = source
    }
}
