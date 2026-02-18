import SwiftUI

struct SettingsView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            Section("Push-to-Talk Hotkey") {
                ShortcutRecorderRow(
                    keyCode: Binding(
                        get: { dependencies.settings.hotkeyKeyCode },
                        set: {
                            dependencies.settings.hotkeyKeyCode = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.hotkeyModifiers },
                        set: {
                            dependencies.settings.hotkeyModifiers = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    )
                )
            }

            Section("After Transcription") {
                Picker("Action", selection: Binding(
                    get: { dependencies.settings.actionType },
                    set: { dependencies.settings.actionType = $0 }
                )) {
                    Text("Paste into active app").tag(PostTranscriptionActionType.paste)
                    Text("Run bash command").tag(PostTranscriptionActionType.bash)
                }
                .pickerStyle(.radioGroup)

                if dependencies.settings.actionType == .bash {
                    TextField("Command (use {} for text)", text: Binding(
                        get: { dependencies.settings.bashCommand },
                        set: { dependencies.settings.bashCommand = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .help("Use {} as placeholder for the transcribed text. Example: pbcopy <<< {}")
                }
            }

            Section("Status") {
                LabeledContent("Transcription") {
                    HStack {
                        Circle()
                            .fill(dependencies.isTranscriptionReady ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(dependencies.initializationStatus)
                    }
                }
                LabeledContent("Hotkey") {
                    Text(dependencies.coordinator.isHotkeyRegistered ? "Registered" : "Not registered")
                        .foregroundStyle(dependencies.coordinator.isHotkeyRegistered ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
    }
}
