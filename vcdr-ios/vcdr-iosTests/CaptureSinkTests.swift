import AVFoundation
import Foundation
import os
import Testing
@testable import vcdr_ios

@Suite("CaptureSink")
struct CaptureSinkTests {
    @Test("a claim revoked while the engine starts opens no capture")
    func revokedClaimOpensNothing() {
        let sink = CaptureSink()
        let run = RunID()

        sink.claim(for: run)
        #expect(sink.close(for: run) == nil)

        #expect(sink.open(for: run) { _ in } == nil)
    }

    @Test("a closed capture hands no more buffers on, and a stale run cannot close a newer one")
    func closedCaptureDropsBuffers() throws {
        let sink = CaptureSink()
        let old = RunID()
        let current = RunID()
        let received = OSAllocatedUnfairLock(initialState: 0)

        sink.claim(for: current)
        #expect(sink.open(for: current) { _ in received.withLock { $0 += 1 } } == CaptureLease(run: current))
        let buffer = try #require(Self.silentBuffer())
        sink.deliver(buffer, level: 0)
        #expect(sink.close(for: old) == nil)
        sink.deliver(buffer, level: 0)

        let tally = try #require(sink.close(for: current))
        sink.deliver(buffer, level: 0)

        #expect(tally.buffers == 2)
        #expect(received.withLock { $0 } == 2)
    }

    private static func silentBuffer() -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) else { return nil }
        buffer.frameLength = 160
        return buffer
    }
}
