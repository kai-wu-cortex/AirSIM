import Foundation
import CryptoKit

enum VoBLEPairingError: Error { case invalidKey }
@MainActor final class Writer: VoBLEMediaWriting {
    var canSendWriteWithoutResponse = true
    var maximumWriteLength = 247
    var writes: [Data] = []
    func writeWithoutResponse(_ data: Data) { writes.append(data) }
}
@main struct MediaParity {
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
    @MainActor static func main() async throws {
        let key = Data(repeating: 7, count: 32)
        let identity = VoBLEMediaSessionIdentity(callID: "fixture", generation: 1)
        let earlyWriter = Writer(), callWriter = Writer()
        let early = VoBLEGATTMediaTransport(writer: earlyWriter)
        let call = VoBLEGATTMediaTransport(writer: callWriter)
        let earlyKey = VoBLEGATTMediaTransport.earlyMediaKey(key, nonce: "fixture-nonce")
        try early.start(identity: identity, mediaKey: earlyKey, receiveOnly: true)
        try call.start(identity: identity, mediaKey: key)
        func packet(_ sequence: UInt32, _ mediaKey: Data) throws -> Data {
            let payload = Data((0..<160).map { UInt8(($0 + Int(sequence)) % 256) })
            let sealed = try VoBLEMediaCipher.seal(payload, key: mediaKey, direction: .downlink,
                streamID: 1, sequence: sequence, timestamp: sequence * 160)
            return try VoBLEAudioPacket(flags: [], codec: .g711MuLaw, streamID: 1, sequence: sequence,
                sampleTimestamp: sequence * 160, payload: sealed.payload,
                authenticationTag: sealed.authenticationTag).encodedFragments(maximumPacketLength: 514)[0]
        }
        // Same sampled speech in both modes; early uses a distinct key. Deliver
        // two frames per notification without creating microphone/uplink traffic.
        for sequence in stride(from: 0, to: 6, by: 2) {
            for (transport, mediaKey) in [(early, earlyKey), (call, key)] {
                let batch = try packet(UInt32(sequence), mediaKey) + packet(UInt32(sequence + 1), mediaKey)
                check(try VoBLEAudioNotification.fragments(batch).count == 2, "batch framing")
                transport.receiveDownlinkFragment(batch)
            }
        }
        for _ in 0..<200 {
            if early.diagnosticSummary.contains("received=6 ") && call.diagnosticSummary.contains("received=6 ") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        var earlyFrames: [VoBLEPlaybackFrame] = [], callFrames: [VoBLEPlaybackFrame] = []
        for _ in 0..<200 {
            if let frame = early.dequeuePlayback() { earlyFrames.append(frame) }
            if let frame = call.dequeuePlayback() { callFrames.append(frame) }
            if earlyFrames.count == 6 && callFrames.count == 6 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(earlyFrames.count == 6 && earlyFrames == callFrames, "early/active decoded audio must be identical")
        check(earlyFrames.allSatisfy { !$0.concealed }, "continuous batch must not conceal samples")
        early.enqueueCapturedPCM(Data(repeating: 1, count: 320))
        call.enqueueCapturedPCM(Data(repeating: 1, count: 320))
        for _ in 0..<100 {
            if !callWriter.writes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(earlyWriter.writes.isEmpty && !callWriter.writes.isEmpty, "early must never send captured PCM")
        // Legacy single-fragment notifications remain supported; malformed suffix
        // rejects the whole notification, not just the second frame.
        let valid = try packet(6, earlyKey)
        check(try VoBLEAudioNotification.fragments(valid).count == 1, "legacy frame")
        for bad in [Data(), valid + Data([1]), Data(repeating: 0, count: 513), Data(valid.dropLast())] {
            do { _ = try VoBLEAudioNotification.fragments(bad); fatalError("malformed batch accepted") }
            catch is VoBLEProtocolError {}
        }
        let receivedBefore = early.diagnosticSummary
        early.receiveDownlinkFragment(valid + Data([1]))
        try await Task.sleep(for: .milliseconds(30))
        check(early.diagnosticSummary == receivedBefore, "partial batch escaped validation")
        var tampered = try packet(7, earlyKey)
        tampered[tampered.count - 1] ^= 1
        early.receiveDownlinkFragment(valid + tampered)
        for _ in 0..<100 {
            if early.diagnosticSummary.contains("invalid=1 ") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(early.diagnosticSummary.contains("received=7 ") && early.diagnosticSummary.contains("invalid=1 "),
              "every batched frame needs its own AEAD validation")
        early.stop(identity: identity)
        try early.start(identity: identity, mediaKey: key, receiveOnly: false)
        early.receiveDownlinkFragment(valid) // Delayed old early-key packet cannot enter the active stream.
        for _ in 0..<100 {
            if early.diagnosticSummary.contains("invalid=1 ") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(early.diagnosticSummary.contains("received=0 ") && early.dequeuePlayback() == nil,
              "early audio leaked after active transition")
        // Negotiated early transport keepalive is authenticated metadata, never PCM.
        let feedbackWriter = Writer()
        let feedback = VoBLEGATTMediaTransport(writer: feedbackWriter)
        try feedback.start(identity: identity, mediaKey: earlyKey, receiveOnly: true, earlyKeepalive: true)
        feedback.enqueueCapturedPCM(Data(repeating: 55, count: 320))
        try await Task.sleep(for: .milliseconds(100))
        check(!feedbackWriter.writes.isEmpty, "negotiated early keepalive never sent")
        var reassembler = VoBLEAudioReassembler()
        var sequences: [UInt32] = []
        for data in feedbackWriter.writes {
            if let packet = try reassembler.append(data, now: Date()) {
                check(packet.streamID == 2, "early transport sent audio stream")
                let payload = try VoBLEMediaCipher.open(.init(payload: packet.payload, authenticationTag: packet.authenticationTag),
                    key: earlyKey, direction: .uplink, streamID: packet.streamID,
                    sequence: packet.sequence, timestamp: packet.sampleTimestamp)
                check(payload.isEmpty, "early transport leaked captured PCM")
                sequences.append(packet.sequence)
            }
        }
        check(!sequences.isEmpty && Set(sequences).count == sequences.count, "keepalive reused nonce")
        feedbackWriter.canSendWriteWithoutResponse = false
        try await Task.sleep(for: .milliseconds(150))
        check(feedback.queuedFrameCount <= 1, "keepalive backlog grew under backpressure")
        feedback.stop(identity: identity)
        let stoppedCount = feedbackWriter.writes.count
        feedbackWriter.canSendWriteWithoutResponse = true
        feedback.peripheralIsReadyToSend()
        try await Task.sleep(for: .milliseconds(60))
        check(feedbackWriter.writes.count == stoppedCount, "keepalive outlived early media")
        try feedback.start(identity: identity, mediaKey: key, earlyKeepalive: true)
        try await Task.sleep(for: .milliseconds(60))
        check(feedbackWriter.writes.count == stoppedCount, "keepalive entered active call")
        feedback.stop(identity: identity)
        print("PASS: identical early/active decoded PCM, batching, legacy framing, malformed bounds, per-frame AEAD, no early PCM uplink, epoch/key isolation, negotiated authenticated keepalive, backpressure, stop/active isolation")
    }
}
