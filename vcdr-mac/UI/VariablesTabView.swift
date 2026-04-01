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
                ForEach(Array(settings.variables.enumerated()), id: \.element.id) { index, _ in
                    VariableRowView(
                        variable: $settings.variables[index],
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
    let onDelete: () -> Void
    @State private var isValueVisible = false

    var body: some View {
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
}
