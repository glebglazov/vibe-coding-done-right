import SwiftUI
import OSLog

private let kbLogger = Logger(subsystem: "glebglazov.vcdr-ios.keyboard", category: "dictate")

/// Dictation bar displayed above the KeyboardKit keyboard.
/// Shows mic (blue) to start, stop (red) during recording.
struct DictateBarView: View {
    let hasFullAccess: Bool
    let openURL: (URL) -> Void

    @State private var isRecording = false
    @State private var isSessionActive = false

    // MARK: - Constants
    private static let barHeight: CGFloat = 40

    var body: some View {
        if !hasFullAccess {
            Text("Enable Full Access in Settings for voice dictation")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }

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
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.body)
                Text(isRecording ? "Stop" : "Dictate")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .background(isRecording ? .red : .blue, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
