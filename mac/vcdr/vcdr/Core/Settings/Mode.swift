import Foundation

struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var actionType: PostTranscriptionActionType
    var bashCommand: String

    static func makeDefault() -> Mode {
        Mode(
            id: UUID(),
            name: "Default",
            actionType: .paste,
            bashCommand: "echo {}"
        )
    }
}
