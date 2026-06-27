import Foundation
import OSLog

/// Last-writer-wins resolution for iCloud `NSFileVersion` siblings on
/// Substitution snapshots. Nonisolated so the file I/O (`Data(contentsOf:)`,
/// `NSFileVersion.replaceItem`) can run off the main thread during an iCloud
/// refresh without freezing the UI.
///
/// Because storage is one file per Substitution, a conflict only ever arises
/// from a *same-entry* concurrent edit — exactly the rare case where LWW is the
/// agreed tie-breaker (per ADR-0004).
enum SubstitutionConflictResolver {

    /// Pure LWW selection: the Substitution with the greatest `lastUpdated`
    /// wins. Factored out so the policy is unit-testable without constructing
    /// real `NSFileVersion` siblings.
    static func winner(among substitutions: [Substitution]) -> Substitution? {
        substitutions.max(by: { $0.lastUpdated < $1.lastUpdated })
    }

    /// Picks the sibling with the greatest `Substitution.lastUpdated`, replaces
    /// the current version if needed, and removes the rest.
    static func resolve(urls: [URL]) {
        for url in urls {
            resolveOne(at: url)
        }
    }

    private static func resolveOne(at url: URL) {
        guard let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
        let others = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        let allVersions: [NSFileVersion] = [current] + others

        let decoder = SubstitutionJSONCoders.makeDecoder()
        let decoded: [(NSFileVersion, Substitution)] = allVersions.compactMap { version in
            guard let data = try? Data(contentsOf: version.url),
                  let substitution = try? decoder.decode(Substitution.self, from: data) else {
                return nil
            }
            return (version, substitution)
        }

        guard let winner = decoded.max(by: { $0.1.lastUpdated < $1.1.lastUpdated }) else {
            Logger.substitutions.error("Conflict at \(url.lastPathComponent) could not be decoded on any version")
            return
        }

        do {
            if winner.0 != current {
                try winner.0.replaceItem(at: url)
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            Logger.substitutions.error("Conflict resolution failed for \(url.lastPathComponent): \(error)")
        }
    }
}
