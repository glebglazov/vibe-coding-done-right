import SwiftUI

struct SubstitutionsTabView: View {
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
                ForEach($viewModel.drafts) { $substitution in
                    SubstitutionRowView(
                        substitution: $substitution,
                        onCommit: { viewModel.persist(substitution) },
                        onDelete: { viewModel.delete(substitution) }
                    )
                }

                Button("Add Substitution") {
                    viewModel.add()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Substitutions")
        .task {
            viewModel.syncFromStore()
        }
    }
}

// MARK: - Substitution Row

private struct SubstitutionRowView: View {
    @Binding var substitution: Substitution
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Trigger Phrase", text: $substitution.triggerPhrase)
                .textFieldStyle(.roundedBorder)

            TextField("Replacement", text: $substitution.replacement, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)

            HStack(spacing: 8) {
                Toggle("Enabled", isOn: $substitution.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(substitution.isEnabled ? "Substitution is active" : "Substitution is disabled")

                Spacer()

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove substitution")
            }
        }
        .onChange(of: substitution) {
            onCommit()
        }
    }
}
