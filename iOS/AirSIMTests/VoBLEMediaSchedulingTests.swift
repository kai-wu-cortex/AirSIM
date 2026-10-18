import Foundation
import XCTest
@testable import AirSIM

final class VoBLEMediaSchedulingTests: XCTestCase {
    // A stalled codec must not hold the main actor in any synchronous facade API.
    @MainActor
    func testLifecycleAndPlaybackReadsReturnWhileCodecQueueIsBlocked() throws {
        let queue = DispatchQueue(label: "VoBLEMediaSchedulingTests.blocked")
        let writer = SchedulingWriterProbe()
        let transport = VoBLEGATTMediaTransport(writer: writer, codecQueue: queue)
        let identity = VoBLEMediaSessionIdentity(callID: "call", generation: 1)
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
        let started = Date()
        try transport.start(identity: identity, mediaKey: Data(repeating: 7, count: 32))
        _ = transport.droppedFrameCount
        _ = transport.diagnosticSummary
        _ = transport.jitterTargetFrames
        XCTAssertNil(transport.dequeuePlayback())
        transport.stop(identity: identity)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1,
                          "Codec backlog must not block the main actor")
        XCTAssertFalse(transport.isRunning)
    }

    // Identity equality alone is insufficient when the same identity is restarted.
    @MainActor
    func testCompletedUplinkCannotEscapeIntoReplacementSession() async throws {
        for replacement in [VoBLEMediaSessionIdentity(callID: "call", generation: 1),
                            VoBLEMediaSessionIdentity(callID: "next", generation: 2)] {
            let queue = DispatchQueue(label: "VoBLEMediaSchedulingTests.epoch")
            let writer = SchedulingWriterProbe()
            let transport = VoBLEGATTMediaTransport(writer: writer, codecQueue: queue)
            try transport.start(identity: .init(callID: "call", generation: 1),
                                mediaKey: Data(repeating: 7, count: 32))
            transport.enqueueCapturedPCM(Data(repeating: 1, count: 320))
            // Finish encryption while the main actor still owns this turn, so
            // its delivery callback cannot run until after replacement.
            queue.sync {}
            try transport.start(identity: replacement, mediaKey: Data(repeating: 8, count: 32))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(writer.writes.isEmpty, "Old encrypted audio must never enter a replacement call")
            transport.enqueueCapturedPCM(Data(repeating: 2, count: 320))
            try await eventually { !writer.writes.isEmpty }
            XCTAssertEqual(writer.writes.count, 1)
            var reassembler = VoBLEAudioReassembler()
            let packet = try XCTUnwrap(try reassembler.append(writer.writes[0]))
            let compressed = try VoBLEMediaCipher.open(
                .init(payload: packet.payload, authenticationTag: packet.authenticationTag),
                key: Data(repeating: 8, count: 32), direction: .uplink, streamID: 1,
                sequence: packet.sequence, timestamp: packet.sampleTimestamp)
            XCTAssertEqual(compressed, VoBLEMULaw.encode(Data(repeating: 2, count: 320)))
        }
    }

    // Dropping only after encryption permits an unbounded queue of captured PCM.
    @MainActor
    func testBlockedEncoderBoundsCapturedWorkBeforeEncryption() async throws {
        let queue = DispatchQueue(label: "VoBLEMediaSchedulingTests.bound")
        let writer = SchedulingWriterProbe()
        let transport = VoBLEGATTMediaTransport(writer: writer, codecQueue: queue)
        try transport.start(identity: .init(callID: "call", generation: 1),
                            mediaKey: Data(repeating: 7, count: 32))
        queue.sync {}
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        // The timeout keeps a regression from permanently wedging the test runner.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { gate.signal() }
        for _ in 0..<1_000 { transport.enqueueCapturedPCM(Data(repeating: 1, count: 320)) }
        XCTAssertEqual(transport.droppedFrameCount, 992,
                       "At most eight captured/encoded frames may survive a codec stall")
        try await eventually { writer.writes.count >= 8 }
        XCTAssertEqual(writer.writes.count, 8)
    }

    @MainActor
    func testDownlinkDecodesRealAudioAndRejectsPlaybackFromReplacedSession() async throws {
        let queue = DispatchQueue(label: "VoBLEMediaSchedulingTests.playback")
        let transport = VoBLEGATTMediaTransport(writer: SchedulingWriterProbe(), codecQueue: queue)
        let identity = VoBLEMediaSessionIdentity(callID: "call", generation: 1)
        let key = Data(repeating: 7, count: 32)
        try transport.start(identity: identity, mediaKey: key)
        for sequence in 0..<8 {
            transport.receiveDownlinkFragment(try downlinkPacket(sequence: UInt32(sequence), key: key))
        }
        try await eventually { transport.diagnosticSummary.contains("received=8 ") }
        // Let the bounded prefetch finish without blocking any main-actor API.
        queue.sync {}
        try await Task.sleep(for: .milliseconds(10))
        let first = try XCTUnwrap(transport.dequeuePlayback())
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.pcm, Data(repeating: 0, count: 320))
        XCTAssertFalse(first.concealed)
        // Complete the refill with this main-actor turn still in progress, then
        // replace with the SAME identity to exercise the independent epoch.
        queue.sync {}
        try transport.start(identity: identity, mediaKey: key)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(transport.dequeuePlayback(), "Old prefetched or in-flight audio must be discarded")
        XCTAssertEqual(transport.droppedFrameCount, 0)
    }

    @MainActor
    func testBlockedDecoderBoundsPendingFragmentsAndKeepsNewestSpeech() async throws {
        let queue = DispatchQueue(label: "VoBLEMediaSchedulingTests.receive-bound")
        let transport = VoBLEGATTMediaTransport(writer: SchedulingWriterProbe(), codecQueue: queue)
        let key = Data(repeating: 7, count: 32)
        let packets = try (0..<100).map { try downlinkPacket(sequence: UInt32($0), key: key) }
        try transport.start(identity: .init(callID: "call", generation: 1), mediaKey: key)
        queue.sync {}
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        defer { gate.signal() }
        for packet in packets { transport.receiveDownlinkFragment(packet) }
        XCTAssertEqual(transport.droppedFrameCount, 35,
                       "One in-flight fragment and 64 pending fragments bound decoder work")
        gate.signal()
        try await eventually { transport.diagnosticSummary.contains("received=65 ") }
        queue.sync {}
        try await Task.sleep(for: .milliseconds(10))
        let frame = try XCTUnwrap(transport.dequeuePlayback())
        XCTAssertGreaterThanOrEqual(frame.sequence, 92,
                                    "A burst must retain the newest eight jitter frames")
        XCTAssertFalse(frame.concealed)
    }

    private func downlinkPacket(sequence: UInt32, key: Data) throws -> Data {
        let timestamp = sequence * 160
        // G.711 mu-law 0xff is exactly a zero-valued PCM sample.
        let sealed = try VoBLEMediaCipher.seal(Data(repeating: 0xff, count: 160), key: key,
                                              direction: .downlink, streamID: 1,
                                              sequence: sequence, timestamp: timestamp)
        let packet = VoBLEAudioPacket(flags: [], codec: .g711MuLaw, streamID: 1,
                                      sequence: sequence, sampleTimestamp: timestamp,
                                      payload: sealed.payload, authenticationTag: sealed.authenticationTag)
        return try XCTUnwrap(packet.encodedFragments(maximumPacketLength: 247).first)
    }

    @MainActor
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Media work did not complete within one second")
    }
}

@MainActor
private final class SchedulingWriterProbe: VoBLEMediaWriting {
    var canSendWriteWithoutResponse = true
    let maximumWriteLength = 247
    private(set) var writes: [Data] = []
    func writeWithoutResponse(_ data: Data) { writes.append(data) }
}
