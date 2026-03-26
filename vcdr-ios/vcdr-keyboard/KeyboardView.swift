import SwiftUI

/// Small mic icon displayed on the right side of the autocomplete toolbar.
/// Blue mic = idle (tap to start recording via deep link).
/// Red stop = recording in background (tap to stop).
struct DictateBarView: View {
    let hasFullAccess: Bool
    weak var keyboardController: KeyboardViewController?

    @State private var isRecording = false

    // MARK: - Constants
    private static let iconSize: CGFloat = 20
    private static let tapTargetSize: CGFloat = 36

    var body: some View {
        Group {
            if isRecording {
                // Recording in progress — tap to stop
                Button {
                    keyboardController?.sendStopCommand()
                    isRecording = false
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: Self.iconSize))
                        .foregroundStyle(.red)
                        .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
                }
            } else {
                // Idle — tap to start via deep link (brief flash to activate session + record)
                Link(destination: SharedConstants.recordDeepLinkURL) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: Self.iconSize))
                        .foregroundStyle(.blue)
                        .frame(width: Self.tapTargetSize, height: Self.tapTargetSize)
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

    private func refreshState() {
        if let rawState = SharedConstants.sharedDefaults.string(forKey: SharedConstants.stateKey),
           let state = RecordingState(rawValue: rawState) {
            isRecording = (state == .recording)
        } else {
            isRecording = false
        }
    }
}
