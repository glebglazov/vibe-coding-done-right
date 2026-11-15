import Foundation

/// What the app says after a Discard, once it is known where the run went.
enum DiscardNote: Equatable {
    case saved(conversationID: UUID)
    case nothingSaved

    var text: String {
        switch self {
        case .saved: "Discarded · saved to History"
        case .nothingSaved: "Discarded"
        }
    }

    init(_ outcome: DiscardedRunOutcome) {
        switch outcome {
        case .saved(let id): self = .saved(conversationID: id)
        case .nothingSaved: self = .nothingSaved
        }
    }
}

/// Owns the note at the bottom of the recording page, and the request to open
/// History on the entry the note is about.
@MainActor
@Observable
final class DiscardNoteCenter {
    private(set) var note: DiscardNote?
    /// The Discarded Conversation that History must open on. VIEW sets it, and
    /// History clears it when it closes.
    var historyFocus: UUID?

    private var expiry: Task<Void, Never>?

    func show(_ outcome: DiscardedRunOutcome) {
        expiry?.cancel()
        note = DiscardNote(outcome)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DiscardTiming.appNote))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    func dismiss() {
        expiry?.cancel()
        note = nil
    }

    /// VIEW: History opens on the saved entry, and the note has done its work.
    func viewInHistory() {
        guard case .saved(let id) = note else { return }
        historyFocus = id
        dismiss()
    }
}
