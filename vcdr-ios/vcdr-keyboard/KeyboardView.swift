import SwiftUI

/// Small mic/stop icon displayed on the right side of the autocomplete toolbar.
/// Toggles between mic (start dictation) and stop (stop recording) based on state.
/// On first tap, deep-links to the main app to activate the audio session.
/// Subsequent taps send commands directly via App Group + Darwin notifications.
struct DictateBarView: View {
    let hasFullAccess: Bool

    @State private var isRecording = false
    @State private var isSessionActive = false

    // MARK: - Constants
    private static let iconSize: CGFloat = 20
    private static let tapTargetSize: CGFloat = 36

    var body: some View {
        Group {
            if !isSessionActive {
                // No active audio session — deep-link to activate, also send start command
                Link(destination: SharedConstants.activateDeepLinkURL) {
                    iconView(name: "mic.fill", color: .blue)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    sendCommand(.startRecording)
                    isRecording = true
                })
            } else if isRecording {
                Button {
                    sendCommand(.stopRecording)
                    isRecording = false
                } label: {
                    iconView(name: "stop.fill", color: .red)
                }
            } else {
                Button {
                    sendCommand(.startRecording)
                    isRecording = true
                } label: {
                    iconView(name: "mic.fill", color: .blue)
                }
            }
        }
        .padding(.trailing, 4)
        .onAppear { refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: .darwinStateChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .darwinTranscriptionReady)) { _ in
            isRecording = false
        }
    }

    private func iconView(name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: Self.iconSize))
            .foregroundStyle(color)
            .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
    }

    private func sendCommand(_ command: RecordingCommand) {
        SharedConstants.sharedDefaults.set(command.rawValue, forKey: SharedConstants.commandKey)
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
    }

    private func refreshState() {
        isSessionActive = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.audioSessionActiveKey)
        if let rawState = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey),
           let state = RecordingState(rawValue: rawState) {
            isRecording = (state == .recording)
        }
    }
}
