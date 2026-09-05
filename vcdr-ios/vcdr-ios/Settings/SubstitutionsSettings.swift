import SwiftUI

/// iOS Substitutions screen. Part of the App Shell — reachable from Settings
/// without Transcription Readiness. Lists, adds, edits, and deletes
/// Substitutions, persisting every change through the `SubstitutionStore`
/// (via the shared `SubstitutionsViewModel`). Shares the view model with the
/// macOS tab; only the presentation is iOS-idiomatic (grouped list, swipe to
/// delete).
struct SubstitutionsSettings: View {
    @State private var viewModel: SubstitutionsViewModel

    init(store: any SubstitutionStore) {
        _viewModel = State(initialValue: SubstitutionsViewModel(store: store))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        Form {
            Section {
                Text("Substitutions swap a spoken Trigger Phrase for fixed Replacement text in your dictation, before any other processing. They apply in every mode and sync across your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if viewModel.drafts.isEmpty {
                    Text("No substitutions yet.")
                        .foregroundStyle(.secondary)
                }

                ForEach($viewModel.drafts) { $substitution in
                    SubstitutionRow(
                        substitution: $substitution,
                        onCommit: { viewModel.commit(substitution) }
                    )
                }
                .onDelete { offsets in
                    for index in offsets {
                        viewModel.delete(viewModel.drafts[index])
                    }
                }
            } footer: {
                Text("Matching is case-insensitive and whole-word. The longest Trigger Phrase wins when two overlap.")
            }

            Section {
                Button {
                    viewModel.add()
                } label: {
                    Label("Add Substitution", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Substitutions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task {
            viewModel.syncFromStore()
        }
    }
}

// MARK: - Substitution Row

private struct SubstitutionRow: View {
    @Binding var substitution: Substitution
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Trigger Phrase", text: $substitution.triggerPhrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("Enabled", isOn: $substitution.isEnabled)
                    .labelsHidden()
            }

            TextField("Replacement", text: $substitution.replacement, axis: .vertical)
                .lineLimit(2...6)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        // Persist on every committed field change; the store stamps lastUpdated
        // and syncs across devices, while the view model keeps row order stable.
        .onChange(of: substitution) {
            onCommit()
        }
    }
}
