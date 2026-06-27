import SwiftUI
import OSLog

/// App Shell actions stay in their own observation scope so Transcription
/// Readiness progress updates cannot interrupt sheet presentation.
struct RecordingTopBar: View {
    let history: (any HistoryStore)?
    let substitutionStore: any SubstitutionStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearance") private var appearance: Appearance = .system
    @State private var showSettings = false
    @State private var showHistory = false
    #if DEBUG
    @State private var showDebugLogs = false
    #endif

    private var theme: Theme { Theme.current(for: colorScheme) }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            #if DEBUG
            debugLogsButton
            #endif
            historyButton
            settingsButton
        }
        .padding(.trailing, 12)
        .padding(.top, 12)
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
            HistorySheet(history: history)
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
            SettingsView(substitutionStore: substitutionStore)
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
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct HistorySheet: View {
    let history: (any HistoryStore)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var theme: Theme { Theme.current(for: colorScheme) }

    var body: some View {
        if let history {
            HistoryView(history: history)
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
