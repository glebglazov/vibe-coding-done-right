import Foundation
import OSLog

/// Moves the Record Files the app kept in its own storage up into the iCloud
/// container, the first time the device syncs a dataset through one.
///
/// Only acts when the container folder is empty AND the local one has files —
/// which guards against a device that has already synced adopting a stale
/// local copy over the one its peers agree on.
///
/// Nonisolated on purpose: this runs behind launch on a GCD thread, because
/// the container it writes into was itself resolved by a blocking call
/// (`ContainerWatcher.resolveStorageRoot()`). The explicit `nonisolated`
/// overrides the target-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// setting.
nonisolated enum RecordFileMigrator {

    static func adoptLocalRecordFiles(from localDirectory: URL, into containerDirectory: URL) {
        guard isEmpty(containerDirectory), !isEmpty(localDirectory) else { return }
        migrate(from: localDirectory, to: containerDirectory)
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

    private static func migrate(from source: URL, to destination: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Logger.sync.error("Could not create migration destination \(destination.path): \(error)")
            return
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Logger.sync.error("Could not enumerate migration source \(source.path)")
            return
        }

        var moved = 0
        var failed = 0
        for fileURL in entries {
            let destURL = destination.appendingPathComponent(fileURL.lastPathComponent)
            do {
                // `setUbiquitous` atomically moves a file into the iCloud
                // container, replica and all.
                try fm.setUbiquitous(true, itemAt: fileURL, destinationURL: destURL)
                moved += 1
            } catch {
                failed += 1
                Logger.sync.error("Migration failed for \(fileURL.lastPathComponent): \(error)")
            }
        }

        Logger.sync.info("Record file migration local → iCloud: moved \(moved), failed \(failed)")
    }
}
