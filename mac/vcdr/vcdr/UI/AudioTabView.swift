import SwiftUI

struct AudioTabView: View {
    let dependencies: AppDependencies

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input Device", selection: Binding(
                    get: { dependencies.audioDeviceMonitor.selectedDeviceID },
                    set: { dependencies.audioDeviceMonitor.selectedDeviceID = $0 }
                )) {
                    ForEach(dependencies.audioDeviceMonitor.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

                if dependencies.hasMicrophonePermission {
                    HStack {
                        Text("Sound Check")
                        Spacer()
                        if dependencies.inputLevelMonitor.isMonitoring {
                            AudioLevelMeter(level: dependencies.inputLevelMonitor.level)
                        }
                        Button(dependencies.inputLevelMonitor.isMonitoring ? "Stop" : "Test") {
                            let enable = !dependencies.inputLevelMonitor.isMonitoring
                            if enable {
                                startLevelMonitoring()
                            } else {
                                dependencies.inputLevelMonitor.stop()
                            }
                        }
                        .controlSize(.small)
                    }
                } else {
                    HStack {
                        Text("Sound Check")
                        Spacer()
                        Text("Microphone permission required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Interaction with OS") {
                Toggle(
                    "Pause media during recording",
                    isOn: Binding(
                        get: { dependencies.settings.audioSettings.pauseMediaDuringRecording },
                        set: { dependencies.settings.audioSettings.pauseMediaDuringRecording = $0 }
                    )
                )
                .help("Automatically pause music and other media while recording, resume when done.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio")
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
}
