import Foundation

enum ActionError: LocalizedError {
    case accessibilityRequired
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Accessibility permissions required. Enable in System Settings > Privacy & Security > Accessibility."
        case .executionFailed(let message):
            "Action failed: \(message)"
        }
    }
}

protocol PostTranscriptionAction: Sendable {
    var name: String { get }
    func execute(text: String) async throws
}
