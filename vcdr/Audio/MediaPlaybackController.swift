import Foundation
import AppKit
import OSLog

@MainActor
final class MediaPlaybackController {
    /// Apps that were paused by us during recording, to be resumed afterwards.
    private var pausedApps: Set<MediaApp> = []

    // MARK: - Supported media apps

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

    // MARK: - Constants

    private static let osascriptPath = "/usr/bin/osascript"

    // MARK: - Pause / Resume

    /// Pauses any currently-playing media apps. Tracks which apps were paused
    /// so that only those apps are resumed later. Unlike the previous CGEvent
    /// media key approach, this sends explicit pause commands via AppleScript —
    /// it will never accidentally start playback or launch an app.
    func pauseIfNeeded() async {
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
            Logger.audio.info("No media apps were playing, nothing paused")
        } else {
            let names = pausedApps.map(\.rawValue).sorted().joined(separator: ", ")
            Logger.audio.info("Paused media apps: \(names)")
        }
    }

    /// Resumes playback in any apps that were paused by ``pauseIfNeeded()``.
    func resumeIfNeeded() async {
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
        Logger.audio.info("Resumed media apps: \(names)")
    }

    // MARK: - AppleScript execution

    /// Runs an AppleScript via `/usr/bin/osascript` off the main thread and
    /// returns the trimmed stdout. Returns `nil` on failure.
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
