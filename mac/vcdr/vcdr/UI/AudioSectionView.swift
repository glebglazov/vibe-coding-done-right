import SwiftUI

struct AudioSectionView: View {
    let deviceMonitor: AudioDeviceMonitor
    let levelMonitor: InputLevelMonitor
    let hasMicrophonePermission: Bool
    let onToggleSoundCheck: (Bool) -> Void

    var body: some View {
        Section("Audio") {
            Picker("Input Device", selection: Binding(
                get: { deviceMonitor.selectedDeviceID },
                set: { deviceMonitor.selectedDeviceID = $0 }
            )) {
                ForEach(deviceMonitor.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            if hasMicrophonePermission {
                HStack {
                    Text("Sound Check")
                    Spacer()
                    if levelMonitor.isMonitoring {
                        AudioLevelMeter(level: levelMonitor.level)
                    }
                    Button(levelMonitor.isMonitoring ? "Stop" : "Test") {
                        onToggleSoundCheck(!levelMonitor.isMonitoring)
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
    }
}

// MARK: - Audio Level Meter

private struct AudioLevelMeter: View {
    let level: Float

    // MARK: - Constants

    private static let meterHeight: CGFloat = 8
    private static let cornerRadius: CGFloat = 4
    private static let yellowThreshold: Float = 0.5
    private static let redThreshold: Float = 0.8

    var body: some View {
        HStack {
            Text("Sound Check")
            Spacer()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(Color.secondary.opacity(0.2))

                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(width: 120, height: Self.meterHeight)
        }
    }

    private var meterColor: Color {
        if level > Self.redThreshold {
            return .red
        } else if level > Self.yellowThreshold {
            return .yellow
        }
        return .green
    }
}
