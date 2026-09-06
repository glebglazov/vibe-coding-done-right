import Foundation
import Testing
@testable import vcdr_mac

@Suite("A model's files on disk")
struct TranscriptionModelFilesTests {

    private let componentNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vcdr-model-files-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func addCompiledComponent(_ name: String, to directory: URL) {
        try! FileManager.default.createDirectory(
            at: directory.appending(path: "\(name).mlmodelc"),
            withIntermediateDirectories: true
        )
    }

    @Test("A directory holding only some of what a model needs is not complete")
    func partialInstallIsNotComplete() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        addCompiledComponent("MelSpectrogram", to: directory)

        #expect(!TranscriptionModelFiles(directory: directory).hasAllComponents(named: componentNames))
    }

    @Test("A directory holding everything a model needs is complete")
    func fullInstallIsComplete() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in componentNames {
            addCompiledComponent(name, to: directory)
        }

        #expect(TranscriptionModelFiles(directory: directory).hasAllComponents(named: componentNames))
    }

    @Test("A source .mlpackage counts the same as a compiled .mlmodelc")
    func sourcePackageAlsoCounts() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        addCompiledComponent("MelSpectrogram", to: directory)
        addCompiledComponent("AudioEncoder", to: directory)
        let packageModel = directory.appending(path: "TextDecoder.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        try! FileManager.default.createDirectory(
            at: packageModel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try! Data().write(to: packageModel)

        #expect(TranscriptionModelFiles(directory: directory).hasAllComponents(named: componentNames))
    }
}
