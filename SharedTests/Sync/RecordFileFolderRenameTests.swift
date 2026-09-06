import Foundation
import Testing
#if os(macOS)
@testable import vcdr_mac
#elseif os(iOS)
@testable import vcdr_ios
#endif

/// What a device finds in place of the folder it stored under the older name.
/// The rename runs behind every launch, so it has to keep every Record File and
/// it has to be silent from the second launch on. One source tree compiled into
/// both `vcdr-macTests` and `vcdr-iosTests`.
@Suite("Record file folder rename")
struct RecordFileFolderRenameTests {

    private let folder = RecordFilesFolder("substitutions", renamedFrom: "Substitutions")

    /// A parent holding `Substitutions` with `count` Record Files in it, as a
    /// device on the older build left it.
    private func makeParent(recordFiles count: Int, named name: String = "Substitutions") -> URL {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("vcdr-rename-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try! fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            try! "{}".write(
                to: directory.appendingPathComponent("record-\(index).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return parent
    }

    private func entries(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test("the name the filesystem stores becomes the lowercase one")
    func renamesTheStoredName() {
        let parent = makeParent(recordFiles: 3)

        RecordFileFolderRename.apply(folder, in: parent)

        #expect(entries(of: parent) == ["substitutions"])
    }

    @Test("every record file is there afterwards")
    func keepsEveryRecordFile() {
        let parent = makeParent(recordFiles: 13)
        let before = entries(of: parent.appendingPathComponent("Substitutions"))

        RecordFileFolderRename.apply(folder, in: parent)

        #expect(entries(of: parent.appendingPathComponent("substitutions")) == before)
    }

    @Test("a second run leaves the folder as the first one left it")
    func isIdempotent() {
        let parent = makeParent(recordFiles: 2)
        RecordFileFolderRename.apply(folder, in: parent)

        RecordFileFolderRename.apply(folder, in: parent)

        #expect(entries(of: parent) == ["substitutions"])
        #expect(entries(of: parent.appendingPathComponent("substitutions")).count == 2)
    }

    @Test("a device that already stores the lowercase name is untouched")
    func leavesAnAlreadyRenamedFolderAlone() {
        let parent = makeParent(recordFiles: 2, named: "substitutions")

        RecordFileFolderRename.apply(folder, in: parent)

        #expect(entries(of: parent) == ["substitutions"])
        #expect(entries(of: parent.appendingPathComponent("substitutions")).count == 2)
    }

    @Test("a folder that was never renamed is left alone")
    func leavesAFolderWithNoOlderNameAlone() {
        let parent = makeParent(recordFiles: 1, named: "conversations")

        RecordFileFolderRename.apply(RecordFilesFolder("conversations"), in: parent)

        #expect(entries(of: parent) == ["conversations"])
    }

    @Test(
        "an older build still reaches the folder by the capitalised name",
        .enabled(if: temporaryVolumeFoldsCase, "a case-sensitive volume cannot answer this")
    )
    func theOlderNameStillResolves() {
        let parent = makeParent(recordFiles: 4)

        RecordFileFolderRename.apply(folder, in: parent)

        // What an older build asks the filesystem for, spelling and all.
        let asOlderBuildsAsk = parent.appendingPathComponent("Substitutions", isDirectory: true)
        #expect(entries(of: asOlderBuildsAsk).count == 4)
    }
}

/// Whether the volume the tests write to folds case, which is the premise the
/// mixed-build window rests on (see `docs/adr/0013`) and not something a test
/// may assume. True on the Mac's case-insensitive APFS boot volume; false
/// inside the simulator's data container, where the older name stays a second
/// real directory and the merge path — not case folding — is what keeps every
/// Record File.
private let temporaryVolumeFoldsCase: Bool = {
    let fm = FileManager.default
    let leaf = "vcdr-case-probe-\(UUID().uuidString)"
    let probe = fm.temporaryDirectory.appendingPathComponent(leaf, isDirectory: true)
    guard (try? fm.createDirectory(at: probe, withIntermediateDirectories: true)) != nil else {
        return false
    }
    defer { try? fm.removeItem(at: probe) }
    let shouted = fm.temporaryDirectory.appendingPathComponent(leaf.uppercased(), isDirectory: true)
    return fm.fileExists(atPath: shouted.path)
}()
