import SwiftUI
import AVFoundation

struct HomeTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            if dependencies.needsPermissionAttention {
                Section {
                    if !dependencies.hasMicrophonePermission {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Microphone")
                                    .fontWeight(.medium)
                                Text("Required to record your voice for transcription.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Grant Access") {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            }
                            .controlSize(.small)
                        }
                    }
                    if !dependencies.hasAccessibilityPermission {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Accessibility")
                                    .fontWeight(.medium)
                                Text("Required to paste transcribed text into active apps.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open Settings") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                } header: {
                    Label("Permissions Required", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("Quick Actions") {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Button(action: { dependencies.coordinator.toggleRecording() }) {
                            Label(
                                isRecording ? "Stop Recording" : "Start Recording",
                                systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                            )
                            .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .red : .accentColor)
                        .disabled(!canToggleRecording)

                        Button(action: { dependencies.modeSwitcherCoordinator.showSwitcher() }) {
                            let mode = dependencies.settings.activeMode
                            let dest = dependencies.settings.outputDestination(for: mode.defaultOutputDestinationID)
                            Text(buildModeLabel(modeName: mode.name, parameterLabels: mode.defaultParameterLabels, destinationSymbol: dest.symbol))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            Section("Mode Switcher") {
                Toggle("Show output destination hint", isOn: Binding(
                    get: { dependencies.settings.showModeSwitcherHint },
                    set: { dependencies.settings.showModeSwitcherHint = $0 }
                ))
                Text("Shows a hint in the mode switcher about pressing ? to see output destinations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ShortcutRecorderRow(
                    label: "Toggle Recording",
                    keyCode: Binding(
                        get: { dependencies.settings.toggleRecordingHotkey.keyCode },
                        set: { dependencies.coordinator.updateToggleRecordingKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.toggleRecordingHotkey.modifiers },
                        set: { dependencies.coordinator.updateToggleRecordingModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Push-to-Type",
                    keyCode: Binding(
                        get: { dependencies.settings.pushToTypeHotkey.keyCode },
                        set: { dependencies.captureCoordinator.updatePushToTypeKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.pushToTypeHotkey.modifiers },
                        set: { dependencies.captureCoordinator.updatePushToTypeModifiers($0) }
                    )
                )
                HStack {
                    Text("Push-to-Type expand delay")
                    Spacer()
                    TextField(
                        "ms",
                        value: Binding(
                            get: { dependencies.settings.pushToTypeExpandDelay },
                            set: { dependencies.settings.pushToTypeExpandDelay = $0 }
                        ),
                        format: .number
                    )
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    Text("ms")
                        .foregroundStyle(.secondary)
                }
                ShortcutRecorderRow(
                    label: "Mode Switcher",
                    keyCode: Binding(
                        get: { dependencies.settings.modeSwitcherHotkey.keyCode },
                        set: { dependencies.modeSwitcherCoordinator.updateModeSwitcherKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.modeSwitcherHotkey.modifiers },
                        set: { dependencies.modeSwitcherCoordinator.updateModeSwitcherModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Cancel Capture",
                    keyCode: Binding(
                        get: { dependencies.settings.cancelRecordingHotkey.keyCode },
                        set: { dependencies.coordinator.updateCancelRecordingKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.cancelRecordingHotkey.modifiers },
                        set: { dependencies.coordinator.updateCancelRecordingModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Copy Latest Capture",
                    keyCode: Binding(
                        get: { dependencies.settings.copyLatestCaptureHotkey.keyCode },
                        set: { dependencies.copyLatestCaptureHandler.updateCopyLatestCaptureKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.copyLatestCaptureHotkey.modifiers },
                        set: { dependencies.copyLatestCaptureHandler.updateCopyLatestCaptureModifiers($0) }
                    )
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private var isRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .preparingToRecord || state == .recording
    }

    private var canToggleRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .idle || state == .preparingToRecord || state == .recording
    }
}
