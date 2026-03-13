import Foundation

struct InputSegment: Identifiable {
    let id: UUID
    var text: String
    var capture: CapturedContext?

    init(text: String = "", capture: CapturedContext? = nil) {
        self.id = UUID()
        self.text = text
        self.capture = capture
    }

    /// Preserves ID for SwiftUI update-in-place (avoids flicker on text edits from coordinator)
    init(id: UUID, text: String, capture: CapturedContext? = nil) {
        self.id = id
        self.text = text
        self.capture = capture
    }
}
