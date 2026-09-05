import SwiftUI
import OSLog

/// App Shell actions stay in their own observation scope so Transcription
/// Readiness progress updates cannot interrupt sheet presentation.
struct RecordingTopBar: View {
    let history: (any HistoryStore)?
    let historySync: SyncReconciler?
    let substitutionStore: any SubstitutionStore
    let substitutionSync: SyncReconciler?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var showSettings = false
    @State private var showHistory = false
    #if DEBUG
    @State private var showDebugLogs = false
    #endif

    /// Tap-target size of one icon, and so the height of the whole cluster.
    /// `RecordingView` reserves this for its header line whether or not the
    /// cluster is rendered, so the status row sharing that line never moves.
    static let height: CGFloat = 44

    private var theme: Theme { Theme.current(for: colorScheme) }

    /// The cluster claims only the width its icons need: it shares its line
    /// with the status row, which takes everything to its left.
    var body: some View {
        HStack(spacing: 0) {
            #if DEBUG
            debugLogsButton
            #endif
            historyButton
            settingsButton
        }
        .padding(.trailing, 12)
    }

    #if DEBUG
    private var debugLogsButton: some View {
        Button {
            showDebugLogs = true
        } label: {
            topBarIcon("doc.text.magnifyingglass")
        }
        .sheet(isPresented: $showDebugLogs) {
            NavigationStack {
                DebugLogView()
            }
            .preferredColorScheme(appearance.colorScheme)
        }
        .accessibilityLabel("Debug Logs")
    }
    #endif

    private var historyButton: some View {
        Button {
            showHistory = true
        } label: {
            topBarIcon("clock.arrow.circlepath")
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(history: history, historySync: historySync)
                .preferredColorScheme(appearance.colorScheme)
        }
    }

    private var settingsButton: some View {
        Button {
            Logger.app.info("[LaunchProbe] settings button tapped main=\(Thread.isMainThread)")
            showSettings = true
            Logger.app.info("[LaunchProbe] settings showSettings=true main=\(Thread.isMainThread)")
        } label: {
            topBarIcon("gearshape")
        }
        .padding(.leading, 4)
        .sheet(isPresented: $showSettings) {
            let _ = Logger.app.info("[LaunchProbe] settings sheet content built main=\(Thread.isMainThread)")
            SettingsView(
                substitutionStore: substitutionStore,
                substitutionSync: substitutionSync
            )
                .preferredColorScheme(appearance.colorScheme)
                .onAppear {
                    Logger.app.info("[LaunchProbe] SettingsView onAppear main=\(Thread.isMainThread)")
                }
        }
    }

    private func topBarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18))
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(width: Self.height, height: Self.height)
            .contentShape(Rectangle())
    }
}

private struct HistorySheet: View {
    let history: (any HistoryStore)?
    let historySync: SyncReconciler?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: Theme { Theme.current(for: colorScheme) }

    var body: some View {
        if let history {
            HistoryView(history: history, historySync: historySync)
        } else {
            NavigationStack {
                ProgressView()
                    .tint(theme.primary)
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.surfaceLowest)
                    .navigationTitle("HISTORY")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                                .foregroundStyle(theme.onSurface)
                        }
                    }
            }
        }
    }
}
