#if DEBUG
import SwiftUI
import UIKit

/// Reads the persistent `LogBuffer` files (App Group container) and renders the
/// merged log, newest writes last. Survives app restarts and includes every
/// level — unlike the old `OSLogStore` reader, which was scoped to the current
/// process and dropped `.debug`/`.info` under the system's retention policy.
struct DebugLogView: View {
    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var justCopied = false
    @State private var sinceMinutes: Int = 60

    private static let windowOptions: [Int] = [15, 60, 240, 1440]

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
                    fetch()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: sinceMinutes) { fetch() }
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

    private func fetch() {
        isLoading = true
        let window = sinceMinutes
        Task.detached(priority: .userInitiated) {
            let fetched = Self.readEntries(sinceMinutes: window)
            await MainActor.run {
                self.lines = fetched
                self.isLoading = false
            }
        }
    }

    /// Merged lines whose timestamp falls within the window. Stored lines start
    /// with a fixed-width sortable timestamp, so a plain `>=` against the cutoff
    /// string filters by age without parsing each line into a `Date`.
    nonisolated private static func readEntries(sinceMinutes: Int) -> [String] {
        let cutoff = LogBuffer.timestamp(Date().addingTimeInterval(-Double(sinceMinutes * 60)))
        return LogBuffer.mergedLines().filter { $0 >= cutoff }
    }
}
#endif
