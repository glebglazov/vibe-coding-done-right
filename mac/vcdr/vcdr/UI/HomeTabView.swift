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

            Section {
                HStack {
                    Spacer()
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
                    Spacer()
                }
            }

            Section("Shortcuts") {
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
        }
        .formStyle(.grouped)
    }

    private var isRecording: Bool {
        dependencies.coordinator.state == .recording
    }

    private var canToggleRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .idle || state == .recording
    }
}
