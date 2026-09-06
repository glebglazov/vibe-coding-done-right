import Foundation

/// One Synced Dataset's folder in the container, and the test for whether a
/// URL the container hands back sits inside it.
///
/// The test walks path components rather than the path string: `conversations`
/// is a prefix of `conversations-archive`, which holds none of its Record
/// Files. It folds case because the spelling is the filesystem's to report —
/// the volume is case-insensitive, so a name the query hands back need not
/// match the case the dataset holds.
nonisolated struct ContainerFolder {

    private let components: [String]

    init(_ directory: URL) {
        components = directory.standardizedFileURL.pathComponents.map { $0.lowercased() }
    }

    /// Whether `url` names something below this folder — a file directly in it,
    /// or anywhere further down.
    func holds(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        guard candidate.count > components.count else { return false }
        return zip(components, candidate).allSatisfy { $0 == $1.lowercased() }
    }
}
