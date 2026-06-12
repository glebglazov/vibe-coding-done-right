#if DEBUG
import SwiftUI
import UIKit

/// Reads the persistent `LogBuffer` file (App Group container) and renders the
/// log, newest writes last. Survives app restarts and includes every
/// level — unlike the old `OSLogStore` reader, which was scoped to the current
/// process and dropped `.debug`/`.info` under the system's retention policy.
struct DebugLogView: View {
    @State private var lines: [String] = []
    @State private var readCursor: LogBuffer.ReadCursor?
    @State private var isLoading = false
    @State private var justCopied = false
    @State private var sinceMinutes: Int = 60
    @State private var isAtBottom = true
    @State private var bottomScrollRequest = 0

    private static let windowOptions: [Int] = [15, 60, 240, 1440]
    private static let bottomAnchorID = "debug-log-bottom"
    private static let bottomDetectionTolerance: CGFloat = 8
    private static let pollInterval: Duration = .seconds(1)
    /// Bounds `LazyVStack` diffing while copy/share still use every fetched
    /// line in the selected window.
    private static let renderedLineLimit = 500

    private var renderedLines: [String] {
        Array(lines.suffix(Self.renderedLineLimit))
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "No log entries",
                    systemImage: "doc.text",
                    description: Text("Nothing logged in the selected window.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(renderedLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchorID)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.visibleRect.maxY >= geometry.contentSize.height - Self.bottomDetectionTolerance
                    } action: { _, newValue in
                        isAtBottom = newValue
                    }
                    .onAppear {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                    .onChange(of: bottomScrollRequest) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Window", selection: $sinceMinutes) {
                        ForEach(Self.windowOptions, id: \.self) { minutes in
                            Text(windowLabel(minutes)).tag(minutes)
                        }
                    }
                } label: {
                    Label(windowLabel(sinceMinutes), systemImage: "clock")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    copyAll()
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                }
                .disabled(lines.isEmpty)
                .accessibilityLabel(justCopied ? "Copied" : "Copy all logs")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !lines.isEmpty {
                    ShareLink(item: lines.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await fetch(reload: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: sinceMinutes) { await pollLogs() }
    }

    private func copyAll() {
        UIPasteboard.general.string = lines.joined(separator: "\n")
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }

    private func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: "Last \(minutes)m"
        case 60: "Last 1h"
        case 1440: "Last 24h"
        default: "Last \(minutes / 60)h"
        }
    }

    private func pollLogs() async {
        readCursor = nil
        await fetch(reload: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await fetch(reload: false)
        }
    }

    private func fetch(reload: Bool) async {
        let shouldShowLoadingIndicator = lines.isEmpty
        if shouldShowLoadingIndicator {
            isLoading = true
        }
        let window = sinceMinutes
        let cursor = reload ? nil : readCursor
        let fetched = await withBlockingTask(qos: .userInitiated) {
            Self.readEntries(sinceMinutes: window, after: cursor)
        }
        guard !Task.isCancelled else { return }
        readCursor = fetched.cursor
        let nextLines = reload
            ? fetched.lines
            : Self.filteredCurrentLines(lines + fetched.lines, sinceMinutes: window)
        let shouldScrollToBottom = isAtBottom && nextLines != lines
        lines = nextLines
        if shouldScrollToBottom {
            bottomScrollRequest += 1
        }
        if shouldShowLoadingIndicator {
            isLoading = false
        }
    }

    /// Merged lines whose timestamp falls within the window. Stored lines start
    /// with a fixed-width sortable timestamp, so a plain `>=` against the cutoff
    /// string filters by age without parsing each line into a `Date`.
    nonisolated private static func readEntries(
        sinceMinutes: Int,
        after cursor: LogBuffer.ReadCursor?
    ) -> LogBuffer.ReadBatch {
        let batch = LogBuffer.readBatch(after: cursor)
        return LogBuffer.ReadBatch(
            lines: filteredCurrentLines(batch.lines, sinceMinutes: sinceMinutes),
            cursor: batch.cursor
        )
    }

    nonisolated private static func filteredCurrentLines(_ lines: [String], sinceMinutes: Int) -> [String] {
        let cutoff = LogBuffer.timestamp(Date().addingTimeInterval(-Double(sinceMinutes * 60)))
        return lines.filter { $0 >= cutoff }
    }
}
#endif
