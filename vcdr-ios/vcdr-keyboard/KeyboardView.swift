import SwiftUI
import OSLog

private let kbLogger = Logger(subsystem: "glebglazov.vcdr-ios.keyboard", category: "dictate")

/// Small mic/stop icon displayed on the right side of the autocomplete toolbar.
struct DictateBarView: View {
    let hasFullAccess: Bool
    /// Opens a URL via extensionContext — provided by KeyboardViewController
    let openURL: (URL) -> Void

    @State private var isRecording = false
    @State private var isSessionActive = false

    // MARK: - Constants
    private static let iconSize: CGFloat = 18
    private static let circleSize: CGFloat = 34

    var body: some View {
        Button {
            if !isSessionActive {
                // No active audio session — open main app to activate
                kbLogger.info("[DictateBar] Tapped mic (session NOT active) — opening activate URL")
                openURL(SharedConstants.activateDeepLinkURL)
            } else if isRecording {
                // Stop recording
                kbLogger.info("[DictateBar] Tapped stop — sending stopRecording")
                sendCommand(.stopRecording)
                isRecording = false
            } else {
                // Start recording (session already active)
                kbLogger.info("[DictateBar] Tapped mic (session active) — sending startRecording")
                sendCommand(.startRecording)
                isRecording = true
            }
        } label: {
            if isRecording {
                iconView(name: "stop.fill", color: .red)
            } else {
                iconView(name: "mic.fill", color: .blue)
            }
        }
        .padding(.trailing, 8)
        .onAppear {
            refreshState()
            kbLogger.info("[DictateBar] onAppear — isSessionActive=\(isSessionActive), isRecording=\(isRecording)")
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
            .foregroundStyle(.white)
            .frame(width: Self.circleSize, height: Self.circleSize)
            .background(color, in: Circle())
            .contentShape(Circle())
    }

    private func sendCommand(_ command: RecordingCommand) {
        kbLogger.info("[DictateBar] sendCommand(\(command.rawValue))")
        SharedConstants.sharedDefaults.set(command.rawValue, forKey: SharedConstants.commandKey)
        DarwinNotificationCenter.post(SharedConstants.commandNotificationName)
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
