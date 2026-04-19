import Foundation
import OSLog

/// Last-write-wins resolution for iCloud `NSFileVersion` siblings on history
/// snapshots. Runs on the main actor to match the project-wide default
/// isolation; conflict events are rare so the blocking cost of
/// `Data(contentsOf:)` on MainActor is acceptable for now.
@MainActor
enum HistoryConflictResolver {

    /// Picks the sibling with the greatest `Conversation.lastUpdated`,
    /// replaces the current version if needed, and removes the rest.
    static func resolve(urls: [URL]) {
        for url in urls {
            resolveOne(at: url)
        }
    }

    private static func resolveOne(at url: URL) {
        guard let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
        let others = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        let allVersions: [NSFileVersion] = [current] + others

        let decoder = HistoryJSONCoders.makeDecoder()
        let decoded: [(NSFileVersion, Conversation)] = allVersions.compactMap { version in
            guard let data = try? Data(contentsOf: version.url),
                  let convo = try? decoder.decode(Conversation.self, from: data) else {
                return nil
            }
            return (version, convo)
        }

        guard let winner = decoded.max(by: { $0.1.lastUpdated < $1.1.lastUpdated }) else {
            Logger.history.error("Conflict at \(url.lastPathComponent) could not be decoded on any version")
            return
        }

        do {
            if winner.0 != current {
                try winner.0.replaceItem(at: url)
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            Logger.history.error("Conflict resolution failed for \(url.lastPathComponent): \(error)")
        }
    }
}
