import SwiftUI

struct AudioTabView: View {
    let audioDeviceMonitor: AudioDeviceMonitor
    let inputLevelMonitor: InputLevelMonitor
    let settings: AppSettings
    let hasMicrophonePermission: Bool

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input Device", selection: Binding(
                    get: { audioDeviceMonitor.selectedDeviceID },
                    set: { audioDeviceMonitor.selectedDeviceID = $0 }
                )) {
                    ForEach(audioDeviceMonitor.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

                if hasMicrophonePermission {
                    HStack {
                        Text("Sound Check")
                        Spacer()
                        if inputLevelMonitor.isMonitoring {
                            AudioLevelMeter(level: inputLevelMonitor.level)
                        }
                        Button(inputLevelMonitor.isMonitoring ? "Stop" : "Test") {
                            inputLevelMonitor.toggle(deviceUID: audioDeviceMonitor.selectedDeviceUID)
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
                        get: { settings.audioSettings.pauseMediaDuringRecording },
                        set: { settings.audioSettings.pauseMediaDuringRecording = $0 }
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
            inputLevelMonitor.stop()
        }
        .onChange(of: audioDeviceMonitor.selectedDeviceID) {
            inputLevelMonitor.restartIfMonitoring(deviceUID: audioDeviceMonitor.selectedDeviceUID)
        }
    }
}
