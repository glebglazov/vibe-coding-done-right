import SwiftUI
import AVFoundation

struct HomeTabView: View {
    let settings: AppSettings
    let coordinator: RecordingCoordinator
    let modeSwitcherCoordinator: ModeSwitcherCoordinator
    let captureCoordinator: CaptureCoordinator
    let copyLatestCaptureHandler: CopyLatestCaptureHandler
    let hasMicrophonePermission: Bool
    let hasAccessibilityPermission: Bool
    let isInitialized: Bool

    private var needsPermissionAttention: Bool {
        isInitialized && (!hasMicrophonePermission || !hasAccessibilityPermission)
    }

    var body: some View {
        Form {
            if needsPermissionAttention {
                Section {
                    if !hasMicrophonePermission {
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
                    if !hasAccessibilityPermission {
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
                        Button(action: { coordinator.toggleRecording() }) {
                            Label(
                                isRecording ? "Stop Recording" : "Start Recording",
                                systemImage: isRecording ? "stop.circle.fill" : "record.circle"
                            )
                            .font(.title3)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isRecording ? .red : .accentColor)
                        .disabled(!canToggleRecording)

                        Button(action: { modeSwitcherCoordinator.showSwitcher() }) {
                            let mode = settings.activeMode
                            let dest = settings.outputDestination(for: mode.defaultOutputDestinationID)
                            Text(buildModeLabel(modeName: mode.name, parameterLabels: mode.defaultParameterLabels, destinationSymbol: dest.symbol))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            Section("Shortcuts") {
                ShortcutRecorderRow(
                    label: "Toggle Recording",
                    keyCode: Binding(
                        get: { settings.toggleRecordingHotkey.keyCode },
                        set: { coordinator.updateToggleRecordingKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { settings.toggleRecordingHotkey.modifiers },
                        set: { coordinator.updateToggleRecordingModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Mode Switcher",
                    keyCode: Binding(
                        get: { settings.modeSwitcherHotkey.keyCode },
                        set: { modeSwitcherCoordinator.updateModeSwitcherKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { settings.modeSwitcherHotkey.modifiers },
                        set: { modeSwitcherCoordinator.updateModeSwitcherModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Cancel Capture",
                    keyCode: Binding(
                        get: { settings.cancelRecordingHotkey.keyCode },
                        set: { coordinator.updateCancelRecordingKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { settings.cancelRecordingHotkey.modifiers },
                        set: { coordinator.updateCancelRecordingModifiers($0) }
                    )
                )
                ShortcutRecorderRow(
                    label: "Copy Latest Capture",
                    keyCode: Binding(
                        get: { settings.copyLatestCaptureHotkey.keyCode },
                        set: { copyLatestCaptureHandler.updateCopyLatestCaptureKeyCode($0) }
                    ),
                    modifiers: Binding(
                        get: { settings.copyLatestCaptureHotkey.modifiers },
                        set: { copyLatestCaptureHandler.updateCopyLatestCaptureModifiers($0) }
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
        let state = coordinator.state
        return state == .preparingToRecord || state == .recording
    }

    private var canToggleRecording: Bool {
        let state = coordinator.state
        return state == .idle || state == .preparingToRecord || state == .recording
    }
}
