//
//  TmuxDestination.swift
//  vcdr
//
//  Created by Gleb Glazov on 21/9/25.
//

import Foundation

class TmuxDestination: TextDestination {
    let name = "Tmux (Claude)"

    private lazy var tmuxPath: String? = {
        let possiblePaths = [
            "/opt/homebrew/bin/tmux",  // Apple Silicon Homebrew
            "/usr/local/bin/tmux",     // Intel Homebrew
            "/usr/bin/tmux"            // System tmux
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                print("✅ TmuxDestination: Found tmux at: \(path)")
                return path
            }
        }

        print("❌ TmuxDestination: tmux not found in any standard location")
        return nil
    }()

    func send(text: String) async throws {
        print("🖥️  TmuxDestination: Looking for Claude session...")

        guard let tmuxPath = tmuxPath else {
            print("❌ TmuxDestination: tmux executable not found")
            throw DestinationError.sendFailed("tmux not installed or not in PATH")
        }

        guard let claudeSession = await findClaudeSession() else {
            print("❌ TmuxDestination: No Claude session found")
            throw DestinationError.unavailable
        }

        print("✅ TmuxDestination: Found Claude session: \(claudeSession)")
        print("📤 TmuxDestination: Sending text to tmux session...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["send-keys", "-t", claudeSession, text]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                print("❌ TmuxDestination: tmux send-keys failed with status \(process.terminationStatus)")
                throw DestinationError.sendFailed("tmux send-keys failed")
            }

            print("✅ TmuxDestination: Successfully sent text to Claude session")
        } catch {
            print("❌ TmuxDestination: Failed to execute tmux: \(error)")
            throw DestinationError.sendFailed("Failed to execute tmux: \(error)")
        }
    }

    func isAvailable() async -> Bool {
        return await findClaudeSession() != nil
    }

    private func findClaudeSession() async -> String? {
        // Get most recently active client session
        guard let currentSession = await getMostRecentSession() else {
            print("ERROR: No tmux clients found")
            return nil
        }

        print("Using most recently active session: \(currentSession)")

        // Check active pane info from target session
        if let activePane = await getActivePaneInfo(session: currentSession) {
            let title = activePane.components(separatedBy: " ").dropFirst().joined(separator: " ")
            // TODO: fix prefix - ✳ symbol gets converted to _ by tmux when encoding special Unicode characters
            if title.hasPrefix("Claude") || title.hasPrefix("claude") || title.hasPrefix("✳") || title.hasPrefix("_") {
                let paneTarget = activePane.components(separatedBy: " ").first ?? ""
                print("Found Claude in active pane by title: \(paneTarget)")
                return paneTarget
            }
        }

        // Search for Claude processes in current session
        if let claudePane = await findClaudePaneInSession(currentSession) {
            print("Found Claude pane: \(claudePane)")
            return claudePane
        }

        print("ERROR: No Claude Code session found in current tmux session '\(currentSession)'")
        return nil
    }

    private func getMostRecentSession() async -> String? {
        let result = await runTmuxCommand(["list-clients", "-F", "#{client_activity} #{client_session}"])
        guard let output = result, !output.isEmpty else { return nil }

        let clients = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !clients.isEmpty else { return nil }

        // Sort by activity (most recent first) and get the session
        let sortedClients = clients.sorted { client1, client2 in
            let activity1 = Int(client1.components(separatedBy: " ").first ?? "0") ?? 0
            let activity2 = Int(client2.components(separatedBy: " ").first ?? "0") ?? 0
            return activity1 > activity2
        }

        return sortedClients.first?.components(separatedBy: " ").last
    }

    private func getActivePaneInfo(session: String) async -> String? {
        return await runTmuxCommand(["display-message", "-t", session, "-p", "#{session_name}:#{window_index}.#{pane_index} #{pane_title}"])
    }

    private func findClaudePaneInSession(_ session: String) async -> String? {
        let result = await runTmuxCommand(["list-panes", "-t", session, "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_title} #{pane_pid} #{pane_active}"])
        guard let output = result else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var claudePanes: [(target: String, isActive: Bool)] = []

        for line in lines {
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 4 else { continue }

            let paneTarget = parts[0]
            let isActive = parts.last == "1"

            // Check title for Claude (starts with)
            let titlePart = parts.dropFirst().joined(separator: " ")
            // TODO: fix prefix - ✳ symbol gets converted to _ by tmux when encoding special Unicode characters
            if titlePart.hasPrefix("Claude") || titlePart.hasPrefix("claude") || titlePart.hasPrefix("✳") || titlePart.hasPrefix("_") {
                claudePanes.append((target: paneTarget, isActive: isActive))
            }
            // Could add process checking here if needed
        }

        // Return focused Claude pane if available, otherwise first one
        if let focusedPane = claudePanes.first(where: { $0.isActive }) {
            return focusedPane.target
        }
        return claudePanes.first?.target
    }

    private func runTmuxCommand(_ arguments: [String]) async -> String? {
        return await withCheckedContinuation { continuation in
            guard let tmuxPath = tmuxPath else {
                print("❌ TmuxDestination: tmux executable not found for command: \(arguments.joined(separator: " "))")
                continuation.resume(returning: nil)
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}