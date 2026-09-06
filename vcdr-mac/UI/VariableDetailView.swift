import SwiftUI

/// The fields the detail view moves the caret between.
private enum VariableField: Hashable {
    case name
    case value
}

/// Edits one Variable: the name scripts reference it by, the value they get —
/// shown only when the user asks for it — and the removal that takes it out of
/// the Secret Store. Pushed from `VariablesListView` via `VariableNavID`.
struct VariableDetailView: View {
    @Binding var variable: Variable
    let notice: ReservedVariableNotice?
    let onRemove: () -> Void

    @State private var isValueVisible = false
    @FocusState private var focus: VariableField?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("VARIABLE_NAME", text: $variable.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($focus, equals: .name)
            } header: {
                Text("Name")
            } footer: {
                Text(VariableCopy.overview)
            }

            Section("Value") {
                HStack(spacing: Self.fieldSpacing) {
                    if isValueVisible {
                        TextField("value", text: $variable.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($focus, equals: .value)
                    } else {
                        SecureField("value", text: $variable.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .focused($focus, equals: .value)
                    }

                    Button {
                        isValueVisible.toggle()
                    } label: {
                        Image(systemName: isValueVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isValueVisible ? "Hide value" : "Show value")
                }
            }

            if let notice {
                Section {
                    ReservedVariableNoticeLabel(notice: notice, text: notice.message)
                        .font(.callout)
                }
            }

            Section {
                Button("Remove Variable", role: .destructive) {
                    // The screen goes first: what it edits is about to stop
                    // existing, and the list behind it is where the user lands.
                    dismiss()
                    onRemove()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(VariableCopy.title(for: variable))
        .onAppear {
            // A Variable arriving here nameless came from the toolbar "+", and
            // the name is the first thing it needs.
            if variable.name.isEmpty {
                focus = .name
            }
        }
    }

    // MARK: - Constants

    private static let fieldSpacing: CGFloat = 8
}
