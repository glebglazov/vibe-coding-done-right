import SwiftUI

/// List of substitutions with NavigationLink rows (chevrons), matching the
/// Modes / Output / Styles tabs. Lives inside a NavigationStack owned by
/// MainWindowView; the detail view and "+" toolbar add come from that shared
/// pattern so every settings list looks and behaves the same.
///
/// Rows lead with the Replacement — the text the user meant — because that is
/// what identifies the entry; the Triggers that produce it read as its
/// description.
struct SubstitutionsListView: View {
    @Bindable var viewModel: SubstitutionsViewModel
    @Binding var path: NavigationPath
    /// Reporting on the Substitution dataset alone: a history backfill running
    /// beside it says nothing about whether the next transcript will use the
    /// Replacements shown here.
    let substitutionSync: SyncReconciler?

    var body: some View {
        let clashes = viewModel.clashes

        List {
            Section {
                Text(SubstitutionCopy.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(viewModel.drafts) { substitution in
                    NavigationLink(value: SubstitutionNavID(id: substitution.id)) {
                        SubstitutionRowView(
                            substitution: substitution,
                            clashes: clashes.clashes(for: substitution)
                        )
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        viewModel.delete(viewModel.drafts[index])
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            SyncIndicator(reconciler: substitutionSync)
                .padding(.trailing, 16)
                .padding(.top, 8)
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
    let clashes: [TriggerPhraseClash]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(SubstitutionCopy.title(for: substitution))
                    .foregroundStyle(substitution.replacement.isEmpty ? .secondary : .primary)
                    .lineLimit(1)

                if let summary = substitution.triggerSummary(losing: clashes) {
                    summary
                        .font(.caption)
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

/// The fields the detail view moves the caret between.
private enum SubstitutionField: Hashable {
    case replacement
    case trigger(Int)
}

struct SubstitutionDetailView: View {
    @Binding var substitution: Substitution
    let clashes: [TriggerPhraseClash]
    let onCommit: () -> Void

    @FocusState private var focus: SubstitutionField?

    var body: some View {
        Form {
            Section {
                TextField("Replacement", text: $substitution.replacement, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focus, equals: .replacement)
            }

            Section("Triggers") {
                ForEach(Array(substitution.livePhrases.enumerated()), id: \.element.id) { index, phrase in
                    TriggerRowView(
                        phrase: $substitution[phrase: phrase.id],
                        clash: clash(for: phrase.text),
                        focus: $focus,
                        field: .trigger(index),
                        onDelete: {
                            substitution.removePhrase(phrase.id)
                        }
                    )
                }

                Button("Add Trigger", action: addTrigger)
            }

            Section {
                Toggle("Enabled", isOn: $substitution.isEnabled)
                    .help(substitution.isEnabled ? "Substitution is active" : "Substitution is disabled")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SubstitutionCopy.title(for: substitution))
        .onChange(of: substitution) {
            onCommit()
        }
        .onAppear {
            if substitution.replacement.isEmpty {
                focus = .replacement
            }
        }
    }

    /// Appends the row and puts the caret in it, so filing a newly discovered
    /// mishearing costs one click and the typing — less than the Replacement a
    /// new Substitution would also need.
    private func addTrigger() {
        substitution.addPhrase()
        focus = .trigger(substitution.livePhrases.count - 1)
    }

    private func clash(for phrase: String) -> TriggerPhraseClash? {
        clashes.first { $0.phrase.lowercased() == phrase.lowercased() }
    }
}

// MARK: - Trigger Row

private struct TriggerRowView: View {
    @Binding var phrase: String
    let clash: TriggerPhraseClash?
    @FocusState.Binding var focus: SubstitutionField?
    let field: SubstitutionField
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Trigger", text: $phrase)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: field)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove trigger")
            }

            if let clash {
                Label {
                    Text(SubstitutionCopy.clashExplanation(clash))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }
}
