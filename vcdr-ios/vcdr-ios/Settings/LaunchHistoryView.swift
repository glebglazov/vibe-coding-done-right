import SwiftUI

/// Renders the persisted launch telemetry ring buffer, newest first. Exists to
/// correlate "slow at times" launches with Launch Verdict, Low Power Mode,
/// thermal state, and reboots on device.
struct LaunchHistoryView: View {
    @State private var records: [LaunchTelemetryRecord] = []

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "No launches recorded",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("A record is added once the model reaches readiness.")
                )
            } else {
                List(records.reversed()) { record in
                    LaunchHistoryRow(record: record)
                }
            }
        }
        .navigationTitle("Launch History")
        .navigationBarTitleDisplayMode(.inline)
        .task { records = await LaunchTelemetry.records() }
    }
}

private struct LaunchHistoryRow: View {
    let record: LaunchTelemetryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(verdictColor)
                Spacer()
                Text(record.timestamp, format: .dateTime.month().day().hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let msToReady = record.msToReady {
                Text("ready in \(formatMs(msToReady))")
                    .font(.system(size: 12, design: .monospaced))
            }
            if let bootstrapLine {
                Text(bootstrapLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(timingsLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if !flags.isEmpty {
                Text(flags.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var verdictColor: Color {
        if record.kind == .backgroundWarm { return .blue }
        switch record.verdict {
        case .warm: return .green
        case .coldSpecialize: return .orange
        case .coldDownload: return .red
        }
    }

    private var title: String {
        switch record.kind {
        case .foregroundLaunch:
            record.verdict.rawValue
        case .backgroundWarm:
            "BACKGROUND_WARM"
        }
    }

    /// The launch costs that are not the model's: history readable and the
    /// record path armed, kept on their own line so they are not read as part
    /// of the model timings below.
    private var bootstrapLine: String? {
        var parts: [String] = []
        if let milliseconds = record.msToHistoryReadable {
            parts.append("history \(formatMs(milliseconds))")
        }
        if let milliseconds = record.msToRecordPathArmed {
            parts.append("record path \(formatMs(milliseconds))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var timingsLine: String {
        "enc \(formatMs(record.encoderMs)) · pre \(formatMs(record.preprocessorMs)) · "
            + "dec \(formatMs(record.decoderMs)) · joint \(formatMs(record.jointMs)) · "
            + "dl \(formatMs(record.downloadMs))"
    }

    private var flags: [String] {
        var flags: [String] = []
        if record.lowPowerMode { flags.append("low power mode") }
        if ProcessInfo.ThermalState(rawValue: record.thermalState) != .nominal {
            flags.append("thermal \(record.thermalStateLabel)")
        }
        if record.rebootedSinceLastLaunch { flags.append("rebooted") }
        return flags
    }

    private func formatMs(_ milliseconds: Double) -> String {
        String(format: "%.0fms", milliseconds)
    }
}
