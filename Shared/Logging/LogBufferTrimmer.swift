import Foundation

nonisolated enum LogBufferTrimmer {
    private static let chunkBytes = 64 * 1024
    private static let newline = UInt8(0x0A)

    struct Result: Sendable {
        let didTrim: Bool
        let keptBytes: Int
    }

    static func trimCutOffset(fileURL: URL, fileSize: Int, trimBytes: Int) -> Int? {
        guard fileSize > trimBytes else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(trimBytes))
            var offset = trimBytes
            while offset < fileSize {
                let chunk = try handle.read(upToCount: min(chunkBytes, fileSize - offset)) ?? Data()
                guard !chunk.isEmpty else { break }
                if let newlineIndex = chunk.firstIndex(of: newline) {
                    return offset + newlineIndex + 1
                }
                offset += chunk.count
            }
            return fileSize
        } catch {
            return nil
        }
    }

    static func trim(sourceURL: URL, temporaryURL: URL, cutOffset: Int) -> Result {
        guard let keptBytes = streamCopySuffix(
            from: sourceURL,
            to: temporaryURL,
            startingAt: UInt64(cutOffset)
        ) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return Result(didTrim: false, keptBytes: 0)
        }

        do {
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: temporaryURL)
            return Result(didTrim: true, keptBytes: keptBytes)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return Result(didTrim: false, keptBytes: keptBytes)
        }
    }

    private static func streamCopySuffix(from sourceURL: URL, to destinationURL: URL, startingAt offset: UInt64) -> Int? {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        guard let input = try? FileHandle(forReadingFrom: sourceURL),
              let output = try? FileHandle(forWritingTo: destinationURL) else {
            return nil
        }
        defer {
            try? input.close()
            try? output.close()
        }

        do {
            try input.seek(toOffset: offset)
            var copiedBytes = 0
            while true {
                let chunk = try input.read(upToCount: chunkBytes) ?? Data()
                guard !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copiedBytes += chunk.count
            }
            return copiedBytes
        } catch {
            return nil
        }
    }
}
