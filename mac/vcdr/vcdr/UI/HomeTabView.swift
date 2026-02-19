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

            AudioSectionView(
                deviceMonitor: dependencies.audioDeviceMonitor,
                levelMonitor: dependencies.inputLevelMonitor,
                hasMicrophonePermission: dependencies.hasMicrophonePermission,
                onToggleSoundCheck: { enabled in
                    if enabled {
                        startLevelMonitoring()
                    } else {
                        dependencies.inputLevelMonitor.stop()
                    }
                }
            )

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
                            Text(dependencies.settings.activeMode.name)
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .onDisappear {
            dependencies.inputLevelMonitor.stop()
        }
        .onChange(of: dependencies.audioDeviceMonitor.selectedDeviceID) {
            // Restart on the new device only if already monitoring
            if dependencies.inputLevelMonitor.isMonitoring {
                startLevelMonitoring()
            }
        }
    }

    private func startLevelMonitoring() {
        dependencies.inputLevelMonitor.start(
            deviceUID: dependencies.audioDeviceMonitor.selectedDeviceUID
        )
    }

    private var isRecording: Bool {
        dependencies.coordinator.state == .recording
    }

    private var canToggleRecording: Bool {
        let state = dependencies.coordinator.state
        return state == .idle || state == .recording
    }
}
