#if DEBUG
import OSLog
import SwiftUI
import UIKit

struct DebugLogView: View {
    @State private var lines: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var justCopied = false
    @State private var sinceMinutes: Int = 60

    private static let windowOptions: [Int] = [15, 60, 240, 1440]

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Reading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Couldn't read logs",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "No log entries",
                    systemImage: "doc.text",
                    description: Text("Nothing from this process in the selected window.")
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
        errorMessage = nil
        let window = sinceMinutes
        Task.detached(priority: .userInitiated) {
            do {
                let fetched = try Self.readEntries(sinceMinutes: window)
                await MainActor.run {
                    self.lines = fetched
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = String(describing: error)
                    self.lines = []
                    self.isLoading = false
                }
            }
        }
    }

    nonisolated private static func readEntries(sinceMinutes: Int) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: Date().addingTimeInterval(-Double(sinceMinutes * 60)))
        let subsystem = Logger.subsystem
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let entries = try store.getEntries(at: start, matching: predicate)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var out: [String] = []
        for entry in entries {
            guard let log = entry as? OSLogEntryLog else { continue }
            let t = formatter.string(from: log.date)
            out.append("\(t) [\(log.category)] [\(levelChar(log.level))] \(log.composedMessage)")
        }
        return out
    }

    nonisolated private static func levelChar(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        case .undefined: "?"
        @unknown default: "?"
        }
    }
}
#endif
