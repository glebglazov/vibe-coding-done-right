import Foundation

/// A Transcription Model's files inside the owned model root: what they cost
/// and how they go away. Neither transcription backend offers an inventory or a
/// delete, so both questions are the directory's to answer.
///
/// Nonisolated to match the model root it reads under, whose callers are the
/// actors that own each model's directory.
nonisolated struct TranscriptionModelFiles: Sendable {
    let directory: URL

    /// Bytes the install occupies, or nil when nothing is there. Summed from
    /// the files themselves because a model is a tree of CoreML bundles, and
    /// the directory entry says nothing about what they weigh.
    var sizeOnDisk: Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return nil }

        var total: Int64?
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            total = (total ?? 0) + Int64(size)
        }
        return total
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// True when every named component is present, compiled (`.mlmodelc`) or
    /// not (`.mlpackage`) — the same two names a CoreML-backed transcription
    /// SDK looks for before it will load a job. Files land one at a time as a
    /// download finishes them, so a directory that exists but is short one
    /// component is an install interrupted partway through, not a finished one.
    func hasAllComponents(named componentNames: [String]) -> Bool {
        componentNames.allSatisfy { name in
            let compiled = directory.appending(path: "\(name).mlmodelc")
            let package = directory.appending(path: "\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
            return FileManager.default.fileExists(atPath: compiled.path)
                || FileManager.default.fileExists(atPath: package.path)
        }
    }
}
