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
                            let parts = [mode.name, mode.defaultParameterLabels, dest.symbol].compactMap { $0 }
                            Text(parts.joined(separator: " · "))
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
                        set: {
                            dependencies.settings.toggleRecordingHotkey.keyCode = $0
                            dependencies.coordinator.updateToggleRecordingHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.toggleRecordingHotkey.modifiers },
                        set: {
                            dependencies.settings.toggleRecordingHotkey.modifiers = $0
                            dependencies.coordinator.updateToggleRecordingHotkey()
                        }
                    )
                )
                ShortcutRecorderRow(
                    label: "Push-to-Talk",
                    keyCode: Binding(
                        get: { dependencies.settings.pushToTalkHotkey.keyCode },
                        set: {
                            dependencies.settings.pushToTalkHotkey.keyCode = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.pushToTalkHotkey.modifiers },
                        set: {
                            dependencies.settings.pushToTalkHotkey.modifiers = $0
                            dependencies.coordinator.updateHotkey()
                        }
                    )
                )
                ShortcutRecorderRow(
                    label: "Push-to-Type",
                    keyCode: Binding(
                        get: { dependencies.settings.pushToTypeHotkey.keyCode },
                        set: {
                            dependencies.settings.pushToTypeHotkey.keyCode = $0
                            dependencies.captureCoordinator.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.pushToTypeHotkey.modifiers },
                        set: {
                            dependencies.settings.pushToTypeHotkey.modifiers = $0
                            dependencies.captureCoordinator.updateHotkey()
                        }
                    )
                )
                ShortcutRecorderRow(
                    label: "Mode Switcher",
                    keyCode: Binding(
                        get: { dependencies.settings.modeSwitcherHotkey.keyCode },
                        set: {
                            dependencies.settings.modeSwitcherHotkey.keyCode = $0
                            dependencies.modeSwitcherCoordinator.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.modeSwitcherHotkey.modifiers },
                        set: {
                            dependencies.settings.modeSwitcherHotkey.modifiers = $0
                            dependencies.modeSwitcherCoordinator.updateHotkey()
                        }
                    )
                )
                ShortcutRecorderRow(
                    label: "Cancel Capture",
                    keyCode: Binding(
                        get: { dependencies.settings.cancelRecordingHotkey.keyCode },
                        set: {
                            dependencies.settings.cancelRecordingHotkey.keyCode = $0
                            dependencies.coordinator.updateCancelRecordingHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.cancelRecordingHotkey.modifiers },
                        set: {
                            dependencies.settings.cancelRecordingHotkey.modifiers = $0
                            dependencies.coordinator.updateCancelRecordingHotkey()
                        }
                    )
                )
                ShortcutRecorderRow(
                    label: "Copy Latest Capture",
                    keyCode: Binding(
                        get: { dependencies.settings.copyLatestCaptureHotkey.keyCode },
                        set: {
                            dependencies.settings.copyLatestCaptureHotkey.keyCode = $0
                            dependencies.copyLatestCaptureHandler.updateHotkey()
                        }
                    ),
                    modifiers: Binding(
                        get: { dependencies.settings.copyLatestCaptureHotkey.modifiers },
                        set: {
                            dependencies.settings.copyLatestCaptureHotkey.modifiers = $0
                            dependencies.copyLatestCaptureHandler.updateHotkey()
                        }
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
        dependencies.coordinator.state == .recording
    }

    private var canToggleRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .idle || state == .recording
    }
}
