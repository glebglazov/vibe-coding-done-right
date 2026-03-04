import Foundation
import OSLog

/// Wraps the mediaremote-adapter Perl script for reading now-playing state
/// and sending explicit pause/play commands via Apple's private MediaRemote
/// framework. The adapter routes calls through `/usr/bin/perl` which carries
/// a `com.apple.perl5` entitlement, granting access on macOS 15.4+.
final class MediaRemoteClient: Sendable {

    // MARK: - Constants

    private static let perlPath = "/usr/bin/perl"
    private static let scriptName = "mediaremote-adapter"
    private static let scriptExtension = "pl"
    private static let libraryName = "MediaRemoteAdapter"
    private static let libraryExtension = "dylib"
    private static let resourceSubdirectory = "MediaRemote"

    // MARK: - Now Playing Info

    struct NowPlayingInfo: Sendable {
        let isPlaying: Bool
        let title: String?
        let bundleIdentifier: String?
    }

    // MARK: - Public API

    /// Tests whether the MediaRemote adapter is functional on this system.
    /// Returns `true` if the adapter responds correctly, `false` otherwise.
    func test() async -> Bool {
        guard let (scriptPath, libraryPath) = resolvePaths() else {
            Logger.audio.warning("MediaRemote adapter resources not found in app bundle")
            return false
        }

        let result = await runAdapter(
            scriptPath: scriptPath,
            libraryPath: libraryPath,
            command: "test"
        )
        let success = result?.exitCode == 0
        Logger.audio.info("MediaRemote adapter test: \(success ? "passed" : "failed")")
        return success
    }

    /// Gets the current now-playing info. Returns `nil` if nothing is playing
    /// or if the adapter is unavailable.
    func getNowPlaying() async -> NowPlayingInfo? {
        guard let (scriptPath, libraryPath) = resolvePaths() else { return nil }

        guard let result = await runAdapter(
            scriptPath: scriptPath,
            libraryPath: libraryPath,
            command: "get"
        ), result.exitCode == 0 else { return nil }

        return parseNowPlayingJSON(result.stdout)
    }

    /// Sends an explicit pause command (MRMediaRemoteSendCommand kMRPause = 1).
    func pause() async {
        guard let (scriptPath, libraryPath) = resolvePaths() else { return }
        _ = await runAdapter(
            scriptPath: scriptPath,
            libraryPath: libraryPath,
            command: "send",
            arguments: ["1"]
        )
        Logger.audio.info("MediaRemote: sent pause command")
    }

    /// Sends an explicit play command (MRMediaRemoteSendCommand kMRPlay = 0).
    func play() async {
        guard let (scriptPath, libraryPath) = resolvePaths() else { return }
        _ = await runAdapter(
            scriptPath: scriptPath,
            libraryPath: libraryPath,
            command: "send",
            arguments: ["0"]
        )
        Logger.audio.info("MediaRemote: sent play command")
    }

    // MARK: - Resource Resolution

    private func resolvePaths() -> (scriptPath: String, libraryPath: String)? {
        guard let scriptPath = Bundle.main.path(
            forResource: Self.scriptName,
            ofType: Self.scriptExtension,
            inDirectory: Self.resourceSubdirectory
        ) else { return nil }

        guard let libraryPath = Bundle.main.path(
            forResource: Self.libraryName,
            ofType: Self.libraryExtension,
            inDirectory: Self.resourceSubdirectory
        ) else { return nil }

        return (scriptPath, libraryPath)
    }

    // MARK: - Process Execution

    private struct ProcessResult: Sendable {
        let stdout: String
        let exitCode: Int32
    }

    private func runAdapter(
        scriptPath: String,
        libraryPath: String,
        command: String,
        arguments: [String] = []
    ) async -> ProcessResult? {
        let callerStart = ContinuousClock.now
        let result = await Task.detached {
            let processStart = ContinuousClock.now
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.perlPath)
            process.arguments = [scriptPath, libraryPath, command] + arguments

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = Pipe() // Discard stderr

            do {
                try process.run()
            } catch {
                Logger.audio.error("Failed to launch MediaRemote adapter: \(error)")
                return nil as ProcessResult?
            }

            // Read stdout BEFORE waitUntilExit to avoid deadlock: the `get`
            // command can output >100KB (base64 artwork), which exceeds the
            // ~64KB macOS pipe buffer. If we wait first, the process blocks
            // on write and waitUntilExit never returns.
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let stdout = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            Logger.audio.info("runAdapter(\(command)): subprocess done (+\(processStart.duration(to: .now)))")
            return ProcessResult(stdout: stdout, exitCode: process.terminationStatus)
        }.value
        Logger.audio.info("runAdapter(\(command)): caller resumed (+\(callerStart.duration(to: .now)) total)")
        return result
    }

    // MARK: - JSON Parsing

    /// Parses the JSON output from the `get` command. Returns `nil` if the
    /// output is `"null"` (nothing playing) or unparseable.
    private func parseNowPlayingJSON(_ json: String) -> NowPlayingInfo? {
        guard json != "null", !json.isEmpty else { return nil }

        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Logger.audio.warning("Failed to parse MediaRemote get output: \(json)")
            return nil
        }

        guard let playing = dict["playing"] as? Bool else { return nil }

        return NowPlayingInfo(
            isPlaying: playing,
            title: dict["title"] as? String,
            bundleIdentifier: dict["bundleIdentifier"] as? String
        )
    }
}
