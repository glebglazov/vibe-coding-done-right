import Foundation
import OSLog
import Testing
@testable import vcdr_ios

@Suite("LogBuffer", .serialized)
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

    @Test("collapses a multi-line message into one stored line")
    func collapsesMultiLineMessageIntoOneLine() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(temporaryLogDirectory()) {
            LogBuffer.shared.append(category: "ai", level: "I", message: "first\nsecond\r\nthird")

            LogBuffer.shared.flushPendingWrites()

            let lines = LogBuffer.mergedLines()
            #expect(lines.count == 1)
            #expect(lines.first?.contains("\n") == false)
            #expect(lines.first?.contains("⏎") == true)
        }
    }

    @Test("clearAll removes stored and pending log lines")
    func clearAllRemovesStoredLines() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(temporaryLogDirectory()) {
            LogBuffer.shared.append(category: "test", level: "I", message: "before clear")
            LogBuffer.shared.flushPendingWrites()

            #expect(LogBuffer.mergedLines().count == 1)

            LogBuffer.shared.clearAll()

            #expect(LogBuffer.mergedLines().isEmpty)
        }
    }

    @Test("cold bootstrap retains every line in emission order")
    func coldBootstrapRetainsLinesInOrder() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(
            temporaryLogDirectory(),
            storageInitiallyReady: false
        ) {
            LogBuffer.shared.append(category: "keyboard", level: "I", message: "first cold line")
            LogBuffer.shared.append(category: "keyboard", level: "I", message: "second cold line")
            LogBuffer.shared.flushPendingWrites()

            let fileURL = LogBuffer.fileURLForTesting()
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))

            LogBuffer.completeBootstrapForTesting()
            LogBuffer.shared.append(category: "keyboard", level: "I", message: "first live line")
            LogBuffer.shared.flushPendingWrites()

            let storedLines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
            #expect(storedLines.count == 3)
            #expect(storedLines[0].hasSuffix("first cold line"))
            #expect(storedLines[1].hasSuffix("second cold line"))
            #expect(storedLines[2].hasSuffix("first live line"))
        }
    }

    @Test("app and keyboard categories share one timestamp-ordered timeline")
    func appAndKeyboardCategoriesShareTimeline() throws {
        try LogBuffer.withTemporaryDirectoryForTesting(temporaryLogDirectory()) {
            Logger.app.info("app timeline marker")
            Logger.keyboard.info("keyboard timeline marker")
            LogBuffer.shared.flushPendingWrites()

            let lines = LogBuffer.mergedLines()
            #expect(lines.count == 2)
            #expect(lines == lines.sorted())
            #expect(lines.contains { $0.contains("[app] [I] app timeline marker") })
            #expect(lines.contains { $0.contains("[keyboard] [I] keyboard timeline marker") })
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
