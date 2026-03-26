import SwiftUI
import OSLog

private let kbLogger = Logger(subsystem: "glebglazov.vcdr-ios.keyboard", category: "dictate")

/// Small mic/stop circle icon displayed above the keyboard, right-aligned.
struct DictateBarView: View {
    let hasFullAccess: Bool
    let openURL: (URL) -> Void

    @State private var isRecording = false
    @State private var isSessionActive = false

    // MARK: - Constants
    private static let iconSize: CGFloat = 18
    private static let circleSize: CGFloat = 34

    var body: some View {
        HStack {
            if !hasFullAccess {
                Text("Enable Full Access for dictation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                kbLogger.info("[DictateBar] Button tapped — isSessionActive=\(isSessionActive), isRecording=\(isRecording)")
                if !isSessionActive {
                    kbLogger.info("[DictateBar] Opening activate URL via extensionContext")
                    openURL(SharedConstants.activateDeepLinkURL)
                } else if isRecording {
                    kbLogger.info("[DictateBar] Sending stopRecording")
                    sendCommand(.stopRecording)
                    isRecording = false
                } else {
                    kbLogger.info("[DictateBar] Sending startRecording")
                    sendCommand(.startRecording)
                    isRecording = true
                }
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: Self.iconSize))
                    .foregroundStyle(.white)
                    .frame(width: Self.circleSize, height: Self.circleSize)
                    .background(isRecording ? .red : .blue, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onAppear {
            refreshState()
            kbLogger.info("[DictateBar] onAppear — isSessionActive=\(isSessionActive), isRecording=\(isRecording)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .darwinStateChanged)) { _ in
            refreshState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .darwinTranscriptionReady)) { _ in
            isRecording = false
        }
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
