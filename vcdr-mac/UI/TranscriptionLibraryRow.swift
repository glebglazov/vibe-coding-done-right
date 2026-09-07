import SwiftUI

/// One Transcription Model in the Library: what it is, what it is doing, and
/// the one action that state allows. This is the only screen that shows a
/// model's state uncollapsed — a download without a progress bar is unusable,
/// so the bar lives here even though the menu bar and the pill keep one label.
struct TranscriptionLibraryRow: View {
    let entry: TranscriptionLibrary.Entry
    /// Why removal is refused, shown next to the disabled button so the reason
    /// is read where the refusal is met.
    let removalRefusal: ModelRemovalRefusal?
    let install: () -> Void
    /// How to remove this install, or nil on a screen that has nowhere to
    /// remove a model from — a Mode's screen shows the model it names, and the
    /// Library is where a model is taken off the disk.
    let remove: (() -> Void)?

    var body: some View {
        LabeledContent {
            if let title = entry.state.installTitle {
                Button(title, action: install)
            } else if entry.state.offersRemoval, let remove {
                Button("Remove", action: remove)
                    .disabled(removalRefusal != nil)
            }
        } label: {
            Text(entry.model.displayName)
            Text(entry.state.label(for: entry.model))
            if let fraction = downloadFraction {
                ProgressView(value: fraction)
            }
            if entry.state.offersRemoval, let removalRefusal {
                Text(removalRefusal.message)
            }
        }
    }

    private var downloadFraction: Double? {
        guard case .downloading(let progress) = entry.state else { return nil }
        return progress.fraction
    }
}
