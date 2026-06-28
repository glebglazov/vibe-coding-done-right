import SwiftUI

/// List of substitutions with NavigationLink rows (chevrons), matching the
/// Modes / Output / Styles tabs. Lives inside a NavigationStack owned by
/// MainWindowView; the detail view and "+" toolbar add come from that shared
/// pattern so every settings list looks and behaves the same.
struct SubstitutionsListView: View {
    @Bindable var viewModel: SubstitutionsViewModel
    @Binding var path: NavigationPath

    var body: some View {
        List {
            Section {
                Text("Substitutions swap a spoken Trigger Phrase for fixed Replacement text in your dictation, before any other processing. They apply in every mode and sync across your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(viewModel.drafts) { substitution in
                    NavigationLink(value: SubstitutionNavID(id: substitution.id)) {
                        SubstitutionRowView(substitution: substitution)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        viewModel.delete(viewModel.drafts[index])
                    }
                }
            }
        }
        .navigationTitle("Substitutions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add new substitution")
            }
        }
        .task {
            viewModel.syncFromStore()
        }
    }

    private func add() {
        let id = viewModel.add()
        path.append(SubstitutionNavID(id: id))
    }
}

// MARK: - Substitution Row

private struct SubstitutionRowView: View {
    let substitution: Substitution

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(substitution.triggerPhrase.isEmpty ? "New Substitution" : substitution.triggerPhrase)
                    .foregroundStyle(substitution.triggerPhrase.isEmpty ? .secondary : .primary)
                if !substitution.replacement.isEmpty {
                    Text(substitution.replacement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !substitution.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(substitution.isEnabled ? 1 : 0.5)
    }
}

// MARK: - Substitution Detail

struct SubstitutionDetailView: View {
    @Binding var substitution: Substitution
    let onCommit: () -> Void

    @FocusState private var isTriggerFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Trigger Phrase", text: $substitution.triggerPhrase)
                    .focused($isTriggerFocused)

                TextField("Replacement", text: $substitution.replacement, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                Toggle("Enabled", isOn: $substitution.isEnabled)
                    .help(substitution.isEnabled ? "Substitution is active" : "Substitution is disabled")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(substitution.triggerPhrase.isEmpty ? "New Substitution" : substitution.triggerPhrase)
        .onChange(of: substitution) {
            onCommit()
        }
        .onAppear {
            if substitution.triggerPhrase.isEmpty {
                isTriggerFocused = true
            }
        }
    }
}
