import Foundation
import Testing
@testable import vcdr_ios

@Suite("LogBuffer")
struct LogBufferTests {
    private static let coalescedLineCount = 3
    private static let trimLineCount = 22_000
    private static let trimPayloadCharacterCount = 1_000
    private static let maxLogBytes = 20 * 1024 * 1024

    @Test("coalesces multiple lines into one flush")
    func coalescesMultipleLinesIntoOneFlush() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(temporaryLogDirectory()) {
            LogBuffer.shared.append(category: "test", level: "I", message: "one")
            LogBuffer.shared.append(category: "test", level: "I", message: "two")
            LogBuffer.shared.append(category: "test", level: "I", message: "three")

            LogBuffer.shared.flushPendingWrites()

            let stats = LogBuffer.instrumentationForTesting()
            #expect(stats.lockCount == 1)
            #expect(stats.flushCount == 1)
            #expect(LogBuffer.mergedLines().count == Self.coalescedLineCount)
        }
    }

    @Test("trim streams kept bytes instead of loading the whole file")
    func trimStreamsKeptBytes() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(temporaryLogDirectory()) {
            for index in 0 ..< Self.trimLineCount {
                LogBuffer.shared.append(
                    category: "trim",
                    level: "I",
                    message: "line-\(index)-\(String(repeating: "x", count: Self.trimPayloadCharacterCount))"
                )
            }

            LogBuffer.shared.flushPendingWrites()

            let stats = LogBuffer.instrumentationForTesting()
            let fileSize = try FileManager.default
                .attributesOfItem(atPath: LogBuffer.fileURLForTesting().path)[.size] as? NSNumber

            #expect(stats.trimCount > 0)
            #expect(stats.streamedTrimBytes > 0)
            #expect((fileSize?.intValue ?? 0) <= Self.maxLogBytes)
            #expect(LogBuffer.mergedLines().first?.contains("line-0-") == false)
        }
    }

    private func temporaryLogDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogBufferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
