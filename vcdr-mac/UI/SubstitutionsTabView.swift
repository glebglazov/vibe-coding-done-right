import SwiftUI

/// List of substitutions with NavigationLink rows (chevrons), matching the
/// Modes / Output / Styles tabs. Lives inside a NavigationStack owned by
/// MainWindowView; the detail view and "+" toolbar add come from that shared
/// pattern so every settings list looks and behaves the same.
///
/// Rows read as the shared presentation layer composes them: the Triggers, an
/// arrow, then the Replacement they produce.
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
        .navigationTitle("Dictionary")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add new entry")
            }
        }
        .onChange(of: viewModel.persisted, initial: true) {
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
            SubstitutionRowLabel(substitution: substitution, clashes: clashes)

            if !substitution.isEnabled {
                Text("Disabled")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
    }
}

// MARK: - Substitution Detail

/// The fields the detail view moves the caret between.
private enum SubstitutionField: Hashable {
    case replacement
    case note
    case trigger(Int)
}

/// The editor for one Dictionary Entry. It asks for the Replacement first,
/// because every entry is a Spelling Hint, then the Note, then the optional
/// Trigger Phrases.
struct SubstitutionDetailView: View {
    @Binding var substitution: Substitution
    let clashes: [TriggerPhraseClash]
    let onCommit: () -> Void

    @FocusState private var focus: SubstitutionField?

    var body: some View {
        Form {
            Section("Spelling") {
                TextField("Spelling", text: $substitution.replacement, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focus, equals: .replacement)
            }

            Section {
                TextField("Note", text: $substitution.note, prompt: Text(SubstitutionCopy.notePlaceholder))
                    .focused($focus, equals: .note)
            } header: {
                Text("Note")
            } footer: {
                Text(SubstitutionCopy.noteCaption)
            }

            Section {
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
            } header: {
                Text("Triggers")
            } footer: {
                Text(SubstitutionCopy.triggersCaption)
            }

            Section {
                Toggle("Enabled", isOn: $substitution.isEnabled)
                    .help(substitution.isEnabled ? "Entry is active" : "Entry is disabled")
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
        .onDisappear {
            substitution.dropBlankPhrases()
        }
    }

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
