import FluidAudio
import Foundation
import OSLog

/// The Launch Verdict: classification of one launch's transcription-model load
/// cost. Mirrors the `[InitTiming] launch verdict=` log line as structured data.
enum LaunchVerdict: String, Codable, Sendable {
    /// Model artifacts were missing on disk and had to be downloaded.
    case coldDownload = "COLD_DOWNLOAD"
    /// Artifacts were on disk but the system ANE/E5RT specialization cache was
    /// purged (reboot, OS/app update, storage pressure), forcing a re-grind.
    case coldSpecialize = "COLD_SPECIALIZE"
    /// All loads hit warm caches.
    case warm = "WARM"
}

/// What `ParakeetProvider` learned about model loading on one launch, handed
/// to `LaunchTelemetry` once Transcription Readiness is reached.
struct LaunchLoadOutcome: Sendable {
    let verdict: LaunchVerdict
    let timings: ParakeetModelLoadTimings
    let downloadMs: Double
}

/// One persisted launch record. Exists to answer "why was THIS launch slow"
/// on-device: verdict × Low Power Mode × thermal state × reboot correlation.
struct LaunchTelemetryRecord: Codable, Sendable, Identifiable {
    let timestamp: Date
    let verdict: LaunchVerdict
    let downloadMs: Double
    let preprocessorMs: Double
    let encoderMs: Double
    let decoderMs: Double
    let jointMs: Double
    /// Process start → Transcription Readiness, wall clock. `nil` when the
    /// process start time could not be read.
    let msToReady: Double?
    let lowPowerMode: Bool
    /// `ProcessInfo.ThermalState` raw value at record time.
    let thermalState: Int
    /// True when the device rebooted since the previous recorded launch — the
    /// event that purges the system ANE specialization cache (expect the next
    /// verdict to be COLD_SPECIALIZE).
    let rebootedSinceLastLaunch: Bool

    var id: Date { timestamp }

    var thermalStateLabel: String {
        switch ProcessInfo.ThermalState(rawValue: thermalState) {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        default: "unknown"
        }
    }
}

/// Ring buffer of per-launch timing records in `UserDefaults`, surfaced in the
/// debug Launch History screen.
@MainActor
enum LaunchTelemetry {
    private static let recordsKey = "launchTelemetry.records"
    private static let lastBootTimeKey = "launchTelemetry.lastBootTime"
    private static let maxRecords = 50
    /// `kern.boottime` jitters by a second or two as the kernel disciplines
    /// the clock; differences inside this window are the same boot.
    private static let bootTimeToleranceSeconds: TimeInterval = 10
    private static let millisecondsPerSecond: Double = 1000
    private static let microsecondsPerSecond: Double = 1_000_000

    private static var recordedThisLaunch = false
    private static var cachedPredictedVerdict: LaunchVerdict?

    // MARK: - Predicted Launch Verdict

    /// Predicted Launch Verdict for this launch, derived from already-persisted
    /// signals before any model load starts: artifacts on disk, the last
    /// telemetry record's verdict, and whether the device rebooted since that
    /// record. Memoized — the coordinator queries it once per launch and later
    /// consumers (parallel warm loads, barrier timebox, perceived readiness)
    /// see the same prediction. Must run before `recordOnce`, which overwrites
    /// the stored boot time the reboot check compares against.
    static func predictedVerdict() async -> LaunchVerdict {
        if let cached = cachedPredictedVerdict { return cached }
        let predicted = await withBlockingTask(qos: .userInitiated) {
            predictVerdict(
                artifactsOnDisk: AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3)),
                lastVerdict: loadRecordsSync().last?.verdict,
                rebootedSinceLastRecord: rebootedSinceLastRecordSync()
            )
        }
        cachedPredictedVerdict = predicted
        return predicted
    }

    /// The prediction decision table, separated from its I/O for testability:
    /// missing artifacts predict Cold Download; no prior telemetry or a reboot
    /// since the last record predicts Cold Specialize (reboot purges the ANE
    /// specialization cache, overriding even a Warm last verdict); only a Warm
    /// last verdict with artifacts intact and no reboot predicts Warm.
    nonisolated static func predictVerdict(
        artifactsOnDisk: Bool,
        lastVerdict: LaunchVerdict?,
        rebootedSinceLastRecord: Bool
    ) -> LaunchVerdict {
        guard artifactsOnDisk else { return .coldDownload }
        guard let lastVerdict, !rebootedSinceLastRecord else { return .coldSpecialize }
        return lastVerdict == .warm ? .warm : .coldSpecialize
    }

    /// Read-only variant of `detectRebootAndRememberBootTime` — compares the
    /// current `kern.boottime` against the one stored on the last recorded
    /// launch without remembering it (that stays `recordOnce`'s job).
    nonisolated private static func rebootedSinceLastRecordSync() -> Bool {
        let previous = UserDefaults.standard.double(forKey: lastBootTimeKey)
        guard previous > 0, let bootTime = currentBootTime() else { return false }
        return abs(bootTime.timeIntervalSince1970 - previous) > bootTimeToleranceSeconds
    }

    /// Appends one record for this launch. Later calls in the same process are
    /// no-ops; defaults I/O runs off the cooperative pool (ADR-0003).
    static func recordOnce(outcome: LaunchLoadOutcome) async {
        guard !recordedThisLaunch else { return }
        recordedThisLaunch = true

        let msToReady = processStartDate().map {
            Date().timeIntervalSince($0) * Self.millisecondsPerSecond
        }
        let rebooted = detectRebootAndRememberBootTime()
        let record = LaunchTelemetryRecord(
            timestamp: Date(),
            verdict: outcome.verdict,
            downloadMs: outcome.downloadMs,
            preprocessorMs: outcome.timings.preprocessorMs,
            encoderMs: outcome.timings.encoderMs,
            decoderMs: outcome.timings.decoderMs,
            jointMs: outcome.timings.jointMs,
            msToReady: msToReady,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            rebootedSinceLastLaunch: rebooted
        )
        await withBlockingTask(qos: .utility) {
            var records = loadRecordsSync()
            records.append(record)
            if records.count > maxRecords {
                records.removeFirst(records.count - maxRecords)
            }
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: recordsKey)
            }
        }
        Logger.app.info(
            "[InitTiming] telemetry recorded verdict=\(record.verdict.rawValue) "
                + "msToReady=\(record.msToReady.map { String(format: "%.0f", $0) } ?? "n/a") "
                + "lpm=\(record.lowPowerMode) thermal=\(record.thermalStateLabel) "
                + "rebooted=\(record.rebootedSinceLastLaunch)"
        )
    }

    /// All persisted records, oldest first.
    static func records() async -> [LaunchTelemetryRecord] {
        await withBlockingTask(qos: .userInitiated) { loadRecordsSync() }
    }

    nonisolated private static func loadRecordsSync() -> [LaunchTelemetryRecord] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
        return (try? JSONDecoder().decode([LaunchTelemetryRecord].self, from: data)) ?? []
    }

    /// Compares the current `kern.boottime` against the one stored on the
    /// previous recorded launch and remembers the current one.
    private static func detectRebootAndRememberBootTime() -> Bool {
        guard let bootTime = currentBootTime() else { return false }
        let defaults = UserDefaults.standard
        let previous = defaults.double(forKey: lastBootTimeKey)
        defaults.set(bootTime.timeIntervalSince1970, forKey: lastBootTimeKey)
        guard previous > 0 else { return false }
        return abs(bootTime.timeIntervalSince1970 - previous) > bootTimeToleranceSeconds
    }

    nonisolated private static func currentBootTime() -> Date? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, UInt32(mib.count), &bootTime, &size, nil, 0) == 0,
              bootTime.tv_sec > 0
        else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
                + TimeInterval(bootTime.tv_usec) / Self.microsecondsPerSecond
        )
    }

    nonisolated private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec)
                + TimeInterval(start.tv_usec) / Self.microsecondsPerSecond
        )
    }
}
