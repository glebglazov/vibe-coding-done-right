import Foundation

/// One Synced Dataset's folder of Record Files: the name it carries under the
/// container's `Documents/VCDR`, and the folder of the same name in the app's
/// own storage that stands in when the device syncs through no container.
///
/// The name is lowercase, because a container folder is a path on a
/// user-visible volume and not a term in the ubiquitous language (see
/// `docs/adr/0013`). Both folders are built from the one name here, so a third
/// dataset inherits the rule instead of taking the instinct of its day.
nonisolated struct RecordFilesFolder: Sendable {

    /// The folder's name, on either side.
    let name: String

    /// The name earlier builds stored for this folder, when it has been
    /// renamed since; nil for a folder that has always had its current name.
    /// `RecordFileFolderRename` is what makes the stored name catch up.
    let renamedFrom: String?

    init(_ name: String, renamedFrom: String? = nil) {
        self.name = name.lowercased()
        self.renamedFrom = renamedFrom
    }

    /// Where the Record Files live when sync is off, or iCloud is unreachable:
    /// the app's own storage, alongside the Local Store.
    var localDirectory: URL {
        FileHistoryStore.localStorageRoot.appendingPathComponent(name)
    }
}
