import SwiftUI

/// The Mac end of the Diagnostics Unlock. Every build shows the persistent log;
/// only a Debug build also carries the test-audio import and the scenario
/// runner, which change how the app behaves and so are not diagnostics.
struct DiagnosticsTabView: View {
    let diagnosticsUnlock: DiagnosticsUnlock
    #if DEBUG
    let session: CaptureSession
    let audioRecorder: AudioRecorder
    let isTranscriptionReady: Bool

    private enum Pane: Hashable {
        case log
        case scenarios
    }

    @State private var pane: Pane = .log
    #endif

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Hide Diagnostics") {
                        diagnosticsUnlock.lock()
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        VStack(spacing: 0) {
            Picker("Pane", selection: $pane) {
                Text("Log").tag(Pane.log)
                Text("Scenarios").tag(Pane.scenarios)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch pane {
            case .log:
                DebugLogView()
            case .scenarios:
                DebugTabView(
                    session: session,
                    audioRecorder: audioRecorder,
                    isTranscriptionReady: isTranscriptionReady
                )
            }
        }
        #else
        DebugLogView()
        #endif
    }
}
