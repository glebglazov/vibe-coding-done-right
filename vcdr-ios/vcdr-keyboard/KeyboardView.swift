import SwiftUI
import OSLog

private let kbLogger = Logger(subsystem: "glebglazov.vcdr-ios.keyboard", category: "dictate")

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
                    kbLogger.info("[DictateBar] Tapped mic (session NOT active) — sending startRecording + deep-linking to activate")
                    sendCommand(.startRecording)
                    isRecording = true
                })
            } else if isRecording {
                Button {
                    kbLogger.info("[DictateBar] Tapped stop — sending stopRecording")
                    sendCommand(.stopRecording)
                    isRecording = false
                } label: {
                    iconView(name: "stop.fill", color: .red)
                }
            } else {
                Button {
                    kbLogger.info("[DictateBar] Tapped mic (session active) — sending startRecording")
                    sendCommand(.startRecording)
                    isRecording = true
                } label: {
                    iconView(name: "mic.fill", color: .blue)
                }
            }
        }
        .padding(.trailing, 4)
        .onAppear {
            refreshState()
            kbLogger.info("[DictateBar] onAppear — isSessionActive=\(isSessionActive), isRecording=\(isRecording), hasFullAccess=\(hasFullAccess)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .darwinStateChanged)) { _ in
            kbLogger.info("[DictateBar] Received darwinStateChanged")
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .darwinTranscriptionReady)) { _ in
            kbLogger.info("[DictateBar] Received darwinTranscriptionReady")
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
        kbLogger.info("[DictateBar] sendCommand(\(command.rawValue))")
        SharedConstants.sharedDefaults.set(command.rawValue, forKey: SharedConstants.commandKey)
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
        kbLogger.info("[DictateBar] Command written and Darwin notification posted")
    }

    private func refreshState() {
        isSessionActive = SharedConstants.sharedDefaults.bool(forKey: SharedConstants.audioSessionActiveKey)
        if let rawState = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey),
           let state = RecordingState(rawValue: rawState) {
            isRecording = (state == .recording)
        }
        kbLogger.info("[DictateBar] refreshState — isSessionActive=\(isSessionActive), isRecording=\(isRecording)")
    }
}
