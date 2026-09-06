import SwiftUI

// MARK: - Copy

/// The words the Variables screens show, so the list and the detail screen call
/// the same thing by the same name.
enum VariableCopy {

    /// The blurb over the list, explaining what a Variable is for.
    static let overview = "Variables are injected as environment variables into all bash scripts. Reference them as $VARIABLE_NAME in your commands."

    /// What a Variable is called while it has no name yet.
    static let untitled = "New Variable"

    /// The name a Variable is known by — the row's prominent half, and the
    /// detail screen's title.
    static func title(for variable: Variable) -> String {
        variable.name.isEmpty ? untitled : variable.name
    }
}

// MARK: - Variables List View

/// List of variables with NavigationLink rows (chevrons), matching the
/// Providers / Substitutions / Output tabs. Lives inside a NavigationStack
/// owned by MainWindowView, which registers the detail destination.
struct VariablesListView: View {
    @Bindable var settings: AppSettings
    @Binding var path: NavigationPath

    var body: some View {
        List {
            Section {
                Text(VariableCopy.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.variables) { variable in
                    NavigationLink(value: VariableNavID(id: variable.id)) {
                        VariableRowView(
                            variable: variable,
                            notice: settings.reservedVariableNotice(for: variable)
                        )
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        settings.deleteVariable(settings.variables[index])
                    }
                }
            }
        }
        .navigationTitle("Variables")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) {
                    Image(systemName: "plus")
                }
                .help("Add new variable")
            }
        }
    }

    private func add() {
        path.append(VariableNavID(id: settings.addVariable()))
    }
}

// MARK: - Variable Row

/// One Variable as a list row: the name it is referenced by, and under it what
/// the scripts will get — masked, because a list is read where anyone can see it.
private struct VariableRowView: View {
    let variable: Variable
    let notice: ReservedVariableNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(VariableCopy.title(for: variable))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(variable.name.isEmpty ? .secondary : .primary)

            if let notice {
                ReservedVariableNoticeLabel(notice: notice, text: notice.summary)
                    .font(.caption)
            } else {
                Text(variable.value.maskedAsSecret)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Reserved Notice

/// A Reserved-key notice with the mark its severity earns: only a diverging
/// override — the one that can surprise — gets the warning glyph and colour.
/// The caller chooses how much of the notice to say and at what size.
struct ReservedVariableNoticeLabel: View {
    let notice: ReservedVariableNotice
    let text: String

    var body: some View {
        Label {
            Text(.init(text))
        } icon: {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
        }
        .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
    }
}
