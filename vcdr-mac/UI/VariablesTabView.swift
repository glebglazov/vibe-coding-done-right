import SwiftUI

struct VariablesTabView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Text("Variables are injected as environment variables into all bash scripts. Reference them as $VARIABLE_NAME in your commands.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(Array(settings.variables.enumerated()), id: \.element.id) { index, variable in
                    VariableRowView(
                        variable: $settings.variables[index],
                        notice: settings.reservedVariableNotice(for: variable),
                        onDelete: {
                            settings.variables.remove(at: index)
                        }
                    )
                }

                Button("Add Variable") {
                    settings.variables.append(Variable())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Variables")
    }
}

// MARK: - Variable Row

private struct VariableRowView: View {
    @Binding var variable: Variable
    let notice: ReservedVariableNotice?
    let onDelete: () -> Void
    @State private var isValueVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            fields
            if let notice {
                noticeLabel(notice)
            }
        }
    }

    private var fields: some View {
        HStack(spacing: 8) {
            TextField("VARIABLE_NAME", text: $variable.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 200)

            if isValueVisible {
                TextField("value", text: $variable.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField("value", text: $variable.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Button {
                isValueVisible.toggle()
            } label: {
                Image(systemName: isValueVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isValueVisible ? "Hide value" : "Show value")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Remove variable")
        }
    }

    @ViewBuilder
    private func noticeLabel(_ notice: ReservedVariableNotice) -> some View {
        Label {
            Text(.init(notice.message))
        } icon: {
            Image(systemName: notice.isWarning ? "exclamationmark.triangle" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
    }
}
