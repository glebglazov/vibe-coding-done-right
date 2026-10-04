import SwiftUI

/// iOS Substitutions screen. Part of the App Shell — reachable from Settings
/// without Transcription Readiness. Two levels, like the macOS tab: a list of
/// Substitutions, each row reading from its Triggers through an arrow to the
/// Replacement they produce, and a screen behind each one where Triggers are
/// added, edited and deleted, then the Replacement they produce is edited.
///
/// Shares the view model and its wording with the macOS tab; only the
/// presentation is iOS-idiomatic (grouped list, swipe to delete).
struct SubstitutionsSettings: View {
    @State private var viewModel: SubstitutionsViewModel
    /// The entry "Add Entry" just drafted, pushed so it opens
    /// ready to type in rather than leaving a nameless row behind.
    @State private var drafted: DraftedSubstitution?

    /// Reporting on the Substitution dataset alone: a history backfill running
    /// beside it says nothing about whether the next transcript will use the
    /// Replacements shown here.
    private let sync: SyncReconciler?

    init(store: any SubstitutionStore, sync: SyncReconciler?) {
        _viewModel = State(initialValue: SubstitutionsViewModel(store: store))
        self.sync = sync
    }

    var body: some View {
        let clashes = viewModel.clashes

        Form {
            Section {
                Text(SubstitutionCopy.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if viewModel.drafts.isEmpty {
                    Text("Your Dictionary is empty.")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.drafts) { substitution in
                    NavigationLink {
                        detail(for: substitution.id)
                    } label: {
                        SubstitutionRowLabel(
                            substitution: substitution,
                            clashes: clashes.clashes(for: substitution)
                        )
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        viewModel.delete(viewModel.drafts[index])
                    }
                }
            } footer: {
                Text(SubstitutionCopy.matchingRules)
            }

            if let sync {
                Section {
                    SyncIndicator(reconciler: sync)
                }
            }

            Section {
                Button {
                    drafted = DraftedSubstitution(id: viewModel.add())
                } label: {
                    Label("Add Entry", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $drafted) { drafted in
            detail(for: drafted.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task {
            viewModel.syncFromStore()
        }
    }

    private func detail(for id: UUID) -> some View {
        let substitution = viewModel.binding(for: id)
        return SubstitutionDetailView(
            substitution: substitution,
            clashes: viewModel.clashes.clashes(for: substitution.wrappedValue),
            onCommit: { viewModel.commit(substitution.wrappedValue) }
        )
    }
}

/// Identity for the navigation push, which needs an `Identifiable` and a raw
/// `UUID` is not one.
private struct DraftedSubstitution: Identifiable, Hashable {
    let id: UUID
}

// MARK: - Substitution Detail

/// The fields the detail view moves the caret between.
private enum SubstitutionField: Hashable {
    case replacement
    case trigger(Int)
}

/// The editor for one Substitution, asking in the order the answers arrive:
/// the Trigger Phrases that were said, then the Replacement they produce — the
/// same order the macOS editor asks in.
private struct SubstitutionDetailView: View {
    @Binding var substitution: Substitution
    let clashes: [TriggerPhraseClash]
    let onCommit: () -> Void

    @FocusState private var focus: SubstitutionField?

    var body: some View {
        Form {
            Section("Triggers") {
                ForEach(Array(substitution.livePhrases.enumerated()), id: \.element.id) { index, phrase in
                    TriggerRow(
                        phrase: $substitution[phrase: phrase.id],
                        clash: clash(for: phrase.text),
                        focus: $focus,
                        field: .trigger(index)
                    )
                }
                .onDelete { offsets in
                    // Resolved to identities before any removal, because
                    // removing one shifts the offsets of the rest.
                    for phrase in offsets.map({ substitution.livePhrases[$0] }) {
                        substitution.removePhrase(phrase.id)
                    }
                }

                Button(action: addTrigger) {
                    Label("Add Trigger", systemImage: "plus")
                }
            }

            Section("Replacement") {
                TextField("Replacement", text: $substitution.replacement, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focus, equals: .replacement)
            }

            Section {
                Toggle("Enabled", isOn: $substitution.isEnabled)
            }
        }
        .navigationTitle(SubstitutionCopy.title(for: substitution))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: substitution) {
            onCommit()
        }
        .onAppear {
            // Unconditionally, because the alternative is a rule that reads the
            // entry to guess what the visit came for — and a wrong guess types a
            // Trigger Phrase into the Replacement. A visit that came to fix the
            // Replacement pays one tap instead.
            addTrigger()
        }
        .onDisappear {
            substitution.dropBlankPhrases()
        }
    }

    /// Appends the row and puts the caret in it, so filing a newly discovered
    /// mishearing costs one tap and the typing — less than the Replacement a
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

private struct TriggerRow: View {
    @Binding var phrase: String
    let clash: TriggerPhraseClash?
    @FocusState.Binding var focus: SubstitutionField?
    let field: SubstitutionField

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A mishearing is often not a word; autocorrect would happily repair
            // it into something the engine never produces, so the Trigger would
            // silently stop matching.
            TextField("Trigger", text: $phrase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)

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
