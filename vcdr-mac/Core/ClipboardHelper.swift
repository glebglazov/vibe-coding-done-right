import AppKit
import OSLog

enum ClipboardHelper {
    /// Pasteboard type that tells clipboard managers not to record this entry.
    /// Community convention: https://nspasteboard.org
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // MARK: - Constants

    /// Delay after Cmd+V before restoring clipboard, allowing the target app to read the paste.
    static let clipboardRestorationDelay: Duration = .milliseconds(500)

    // MARK: - Snapshot

    /// Snapshot of all pasteboard items for later restoration.
    struct PasteboardSnapshot {
        struct Item {
            let types: [NSPasteboard.PasteboardType]
            let dataByType: [NSPasteboard.PasteboardType: Data]
        }
        let items: [Item]
        let isEmpty: Bool
    }

    // MARK: - Standard Write

    /// Writes a string to the general pasteboard, clearing existing contents first.
    static func writeString(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Clipboard Preservation

    /// Saves all current pasteboard contents (all types) for later restoration.
    static func saveContents() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return PasteboardSnapshot(items: [], isEmpty: true)
        }

        let snapshotItems = items.map { item -> PasteboardSnapshot.Item in
            let types = item.types
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardSnapshot.Item(types: types, dataByType: dataByType)
        }
        Logger.actions.info("Saved pasteboard contents: \(snapshotItems.count) item(s)")
        return PasteboardSnapshot(items: snapshotItems, isEmpty: false)
    }

    /// Writes a string to the pasteboard marked with ConcealedType so clipboard managers ignore it.
    static func writeConcealedString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Mark as concealed — empty data signals "don't record" to clipboard managers
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])
    }

    /// Restores previously saved pasteboard contents.
    static func restoreContents(_ snapshot: PasteboardSnapshot) {
        guard !snapshot.isEmpty else {
            Logger.actions.info("No pasteboard contents to restore")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let items = snapshot.items.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for type in snapshotItem.types {
                if let data = snapshotItem.dataByType[type] {
                    item.setData(data, forType: type)
                }
            }
            return item
        }
        pasteboard.writeObjects(items)
        Logger.actions.info("Restored pasteboard contents: \(items.count) item(s)")
    }
}
