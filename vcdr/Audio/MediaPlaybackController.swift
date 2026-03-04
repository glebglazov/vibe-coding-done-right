import Foundation
import AppKit
import OSLog

@MainActor
final class MediaPlaybackController {
    private let mediaRemoteClient = MediaRemoteClient()

    // MARK: - Backend Selection

    private enum Backend {
        case mediaRemote
        case appleScript
    }

    /// Resolved lazily on first `pauseIfNeeded()` call via the adapter's `test` command.
    private var backend: Backend?

    // MARK: - State tracking

    /// MediaRemote backend: whether we sent a pause command this session.
    private var didPauseViaMediaRemote = false
    /// AppleScript backend: which specific apps we paused this session.
    private var pausedApps: Set<MediaApp> = []

    // MARK: - Pause / Resume

    /// Pauses the active media player if anything is currently playing.
    /// On first call, detects whether the MediaRemote adapter is available
    /// and caches the result for all subsequent calls.
    func pauseIfNeeded() async {
        let start = ContinuousClock.now
        let backend = await resolveBackend()
        Logger.audio.info("pauseIfNeeded: resolveBackend done (+\(start.duration(to: .now)))")

        switch backend {
        case .mediaRemote:
            await pauseViaMediaRemote()
        case .appleScript:
            await pauseViaAppleScript()
        }
        Logger.audio.info("pauseIfNeeded: complete (+\(start.duration(to: .now)))")
    }

    /// Resumes playback in any apps that were paused by ``pauseIfNeeded()``.
    func resumeIfNeeded() async {
        guard let backend else { return }

        switch backend {
        case .mediaRemote:
            await resumeViaMediaRemote()
        case .appleScript:
            await resumeViaAppleScript()
        }
    }

    // MARK: - Backend Resolution

    private func resolveBackend() async -> Backend {
        if let backend {
            Logger.audio.info("resolveBackend: cached (\(String(describing: backend)))")
            return backend
        }

        let testStart = ContinuousClock.now
        let available = await mediaRemoteClient.test()
        Logger.audio.info("resolveBackend: test() done (+\(testStart.duration(to: .now))), available=\(available)")
        let resolved: Backend = available ? .mediaRemote : .appleScript
        backend = resolved

        Logger.audio.info("Media playback backend: \(available ? "MediaRemote" : "AppleScript")")
        return resolved
    }

    // MARK: - MediaRemote Backend

    private func pauseViaMediaRemote() async {
        didPauseViaMediaRemote = false

        let getNowPlayingStart = ContinuousClock.now
        guard let nowPlaying = await mediaRemoteClient.getNowPlaying(),
              nowPlaying.isPlaying else {
            Logger.audio.info("MediaRemote: nothing playing, skipping pause (+\(getNowPlayingStart.duration(to: .now)) for getNowPlaying)")
            return
        }

        await mediaRemoteClient.pause()
        didPauseViaMediaRemote = true
        Logger.audio.info("MediaRemote: paused (\(nowPlaying.title ?? "unknown"))")
    }

    private func resumeViaMediaRemote() async {
        guard didPauseViaMediaRemote else { return }
        didPauseViaMediaRemote = false

        await mediaRemoteClient.play()
        Logger.audio.info("MediaRemote: resumed playback")
    }

    // MARK: - AppleScript Backend (fallback)

    private enum MediaApp: String, CaseIterable, Hashable {
        case music = "Music"
        case spotify = "Spotify"

        /// AppleScript that checks if the app is running and currently playing,
        /// and pauses it if so. Returns "paused" when it actually paused the app,
        /// "skipped" otherwise. The `application is running` guard prevents macOS
        /// from launching the app just to send it a command.
        var pauseScript: String {
            """
            if application "\(rawValue)" is running then
                tell application "\(rawValue)"
                    if player state is playing then
                        pause
                        return "paused"
                    end if
                end tell
            end if
            return "skipped"
            """
        }

        /// AppleScript that resumes playback if the app is still running.
        var resumeScript: String {
            """
            if application "\(rawValue)" is running then
                tell application "\(rawValue)"
                    play
                end tell
            end if
            """
        }
    }

    private static let osascriptPath = "/usr/bin/osascript"

    private func pauseViaAppleScript() async {
        pausedApps = []

        await withTaskGroup(of: MediaApp?.self) { group in
            for app in MediaApp.allCases {
                group.addTask {
                    let result = await self.runAppleScript(app.pauseScript)
                    return result == "paused" ? app : nil
                }
            }

            for await app in group {
                if let app {
                    pausedApps.insert(app)
                }
            }
        }

        if pausedApps.isEmpty {
            Logger.audio.info("AppleScript: no media apps were playing, nothing paused")
        } else {
            let names = pausedApps.map(\.rawValue).sorted().joined(separator: ", ")
            Logger.audio.info("AppleScript: paused \(names)")
        }
    }

    private func resumeViaAppleScript() async {
        guard !pausedApps.isEmpty else { return }

        let appsToResume = pausedApps
        pausedApps = []

        await withTaskGroup(of: Void.self) { group in
            for app in appsToResume {
                group.addTask {
                    _ = await self.runAppleScript(app.resumeScript)
                }
            }
        }

        let names = appsToResume.map(\.rawValue).sorted().joined(separator: ", ")
        Logger.audio.info("AppleScript: resumed \(names)")
    }

    private func runAppleScript(_ source: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MediaPlaybackController.osascriptPath)
            process.arguments = ["-e", source]

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                Logger.audio.error("Failed to launch osascript: \(error)")
                return nil as String?
            }

            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
