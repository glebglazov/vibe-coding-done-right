import Foundation
import OSLog

/// Reconciles the local and ubiquity `conversations/` directories at app
/// launch based on whether sync is enabled. Runs before the active
/// `HistoryStore` is constructed so whichever directory ends up in use is
/// already populated with the user's expected data.
///
/// Only acts when the destination is empty AND the source has files — this
/// guards against overwriting an authoritative copy when the user has
/// toggled the setting multiple times.
///
/// Nonisolated on purpose: this runs during app launch and the first call to
/// `UbiquityHistoryStore.resolveStorageRoot()` synchronously provisions the
/// iCloud container, which can block for seconds on the first launch after
/// install. Callers dispatch this to a detached task so the main actor stays
/// free to render the first frame. The explicit `nonisolated` overrides the
/// target-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.
nonisolated enum HistoryMigrator {

    static func reconcileAtLaunch(syncEnabled: Bool) {
        let localRoot = FileHistoryStore.localStorageRoot
            .appendingPathComponent("conversations")
        guard let ubiquityRoot = UbiquityHistoryStore.resolveStorageRoot()?
            .appendingPathComponent("conversations") else {
            // No iCloud — nothing to reconcile.
            return
        }

        if syncEnabled, isEmpty(ubiquityRoot), !isEmpty(localRoot) {
            migrate(from: localRoot, to: ubiquityRoot, makeUbiquitous: true)
        } else if !syncEnabled, isEmpty(localRoot), !isEmpty(ubiquityRoot) {
            migrate(from: ubiquityRoot, to: localRoot, makeUbiquitous: false)
        }
    }

    // MARK: - Helpers

    private static func isEmpty(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        // Ignore dotfiles like `.migrated` so the directory is treated as
        // "empty" for the purpose of first-time migration.
        return contents.allSatisfy { $0.hasPrefix(".") }
    }

    private static func migrate(from source: URL, to destination: URL, makeUbiquitous: Bool) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Logger.history.error("Could not create migration destination \(destination.path): \(error)")
            return
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Logger.history.error("Could not enumerate migration source \(source.path)")
            return
        }

        var moved = 0
        var failed = 0
        for fileURL in entries {
            let destURL = destination.appendingPathComponent(fileURL.lastPathComponent)
            do {
                // `setUbiquitous` atomically moves a file into/out of the
                // iCloud container. On the reverse path, iCloud will remove
                // the source replica once the move propagates.
                try fm.setUbiquitous(makeUbiquitous, itemAt: fileURL, destinationURL: destURL)
                moved += 1
            } catch {
                failed += 1
                Logger.history.error("Migration failed for \(fileURL.lastPathComponent): \(error)")
            }
        }

        let direction = makeUbiquitous ? "local → iCloud" : "iCloud → local"
        Logger.history.info("History migration \(direction): moved \(moved), failed \(failed)")
    }
}
