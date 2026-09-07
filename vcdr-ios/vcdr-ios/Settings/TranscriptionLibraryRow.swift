import SwiftUI

/// One Transcription Model in the Library: what it is, what it is doing, and
/// the one action that state allows. This is the only screen that shows a
/// model's state uncollapsed — a download without a progress bar is unusable,
/// so the bar lives here even though the recording screen and the keyboard keep
/// one label.
struct TranscriptionLibraryRow: View {

    // MARK: - Constants

    private static let rowSpacing: CGFloat = 6

    let entry: TranscriptionLibrary.Entry
    /// Why removal is refused, shown next to the disabled button so the reason
    /// is read where the refusal is met.
    let removalObjection: ModelRemovalObjection?
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            LabeledContent {
                action
            } label: {
                Text(entry.model.displayName)
                Text(entry.state.label(for: entry.model))
            }
            if let fraction = downloadFraction {
                ProgressView(value: fraction)
            }
            if entry.state.offersRemoval, let removalObjection {
                Text(removalObjection.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        if let title = entry.state.installTitle {
            // Borderless, because a Form row taps as a whole otherwise and a
            // tap anywhere in the row would install a model nobody asked for.
            Button(title, action: install)
                .buttonStyle(.borderless)
        } else if entry.state.offersRemoval {
            Button("Remove", action: remove)
                .buttonStyle(.borderless)
                .disabled(removalObjection != nil)
        }
    }

    private var downloadFraction: Double? {
        guard case .downloading(let progress) = entry.state else { return nil }
        return progress.fraction
    }
}
