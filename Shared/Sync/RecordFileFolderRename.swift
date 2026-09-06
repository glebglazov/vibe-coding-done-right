import Foundation
import OSLog

/// Gives a dataset's folder the name the app now uses, on a device whose
/// filesystem still stores the older one.
///
/// The folder is visible to the user, in Files.app and in Finder, so the name
/// the filesystem stores has to change and not only the constant the code
/// holds (see `docs/adr/0013`). On a case-insensitive volume the two names are
/// one directory, so the code cannot ask whether the new name resolves — it
/// always does. The only honest question is whether the parent still lists the
/// older name exactly, which is also what makes every run after the first one
/// silent.
///
/// A peer device on an older build keeps asking iCloud for the older name. The
/// volume folds case, so it reaches the renamed folder and keeps working: that
/// is what makes this rename safe to ship while older builds are in the field,
/// and no Record File is stranded by it.
///
/// Nonisolated on purpose: this runs behind launch on a GCD thread, alongside
/// `RecordFileMigrator`, because the container it renames inside was itself
/// resolved by a blocking call. The explicit `nonisolated` overrides the
/// target-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.
nonisolated enum RecordFileFolderRename {

    /// Renames the folder the device uses when it syncs through no container,
    /// so a device with sync off reads the same name as one with sync on.
    static func applyLocally(_ folder: RecordFilesFolder) {
        apply(folder, in: folder.localDirectory.deletingLastPathComponent())
    }

    /// Renames `folder`'s older name to its current one inside `parent`, when
    /// `parent` still holds that older name. Does nothing, and says nothing,
    /// when it does not.
    static func apply(_ folder: RecordFilesFolder, in parent: URL) {
        guard let legacyName = folder.renamedFrom, lists(legacyName, in: parent) else { return }

        let fm = FileManager.default
        // Out of the way first, under a name neither spelling can be. On a
        // case-insensitive volume the destination is this same directory, and
        // on a case-sensitive one it may be a second real directory holding
        // Record Files of its own; moving aside is the one step that collides
        // with neither.
        let staging = parent.appendingPathComponent(".\(folder.name)-renaming-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: parent.appendingPathComponent(legacyName), to: staging)
        } catch {
            Logger.sync.error("Could not rename \(legacyName) in \(parent.path): \(error)")
            return
        }

        if fm.fileExists(atPath: parent.appendingPathComponent(folder.name).path) {
            merge(staging, into: parent.appendingPathComponent(folder.name))
        } else {
            adopt(staging, as: folder.name, in: parent, renamedFrom: legacyName)
        }
    }

    // MARK: - Helpers

    /// Whether `parent` holds an entry spelled exactly `name` — the one test a
    /// case-folding volume cannot answer with a plain `fileExists`.
    private static func lists(_ name: String, in parent: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return contents.contains(name)
    }

    private static func adopt(
        _ staging: URL,
        as name: String,
        in parent: URL,
        renamedFrom legacyName: String
    ) {
        do {
            try FileManager.default.moveItem(at: staging, to: parent.appendingPathComponent(name))
            Logger.sync.info("Renamed record file folder \(legacyName) to \(name) in \(parent.path)")
        } catch {
            Logger.sync.error("""
                Could not rename \(legacyName) to \(name) in \(parent.path): \(error) — \
                its record files are in \(staging.lastPathComponent)
                """)
        }
    }

    /// Both spellings were real directories, which a case-sensitive volume
    /// allows. Every Record File joins the one the app now reads rather than
    /// either directory replacing the other, and a file that cannot be moved
    /// stays where it is: the moved-aside folder is kept, and named in the log,
    /// rather than anything being deleted to make the merge tidy.
    private static func merge(_ staging: URL, into destination: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            Logger.sync.error("Could not enumerate \(staging.path) to merge it into \(destination.path)")
            return
        }

        var moved = 0
        var failed = 0
        for fileURL in entries {
            do {
                try fm.moveItem(at: fileURL, to: destination.appendingPathComponent(fileURL.lastPathComponent))
                moved += 1
            } catch {
                failed += 1
                Logger.sync.error("Could not move \(fileURL.lastPathComponent) into \(destination.path): \(error)")
            }
        }

        Logger.sync.info("Merged record file folders into \(destination.path): moved \(moved), failed \(failed)")
        if failed == 0 {
            try? fm.removeItem(at: staging)
        }
    }
}
