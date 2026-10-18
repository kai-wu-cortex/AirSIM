import Foundation

enum VoBLEProtocolError: Error, Equatable {
    case packetTooSmall
    case invalidMagic
    case unsupportedVersion
    case invalidType
    case invalidLength
    case invalidFragment
    case tooManyFragments
    case frameTooLarge
    case inconsistentFrame
}

struct VoBLEAudioFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let start = Self(rawValue: 1 << 0)
    static let end = Self(rawValue: 1 << 1)
    static let silence = Self(rawValue: 1 << 2)
    static let discontinuity = Self(rawValue: 1 << 3)
    static let fec = Self(rawValue: 1 << 4)
}

enum VoBLEAudioCodec: UInt8, Sendable {
    case g711MuLaw = 1
}

struct VoBLEAudioPacket: Equatable, Sendable {
    static let headerLength = 18
    static let authenticationTagLength = 16
    static let maximumFragmentCount = 64
    static let maximumPayloadLength = 512

    let flags: VoBLEAudioFlags
    let codec: VoBLEAudioCodec
    let streamID: UInt8
    let sequence: UInt32
    let sampleTimestamp: UInt32
    let payload: Data
    let authenticationTag: Data

    func encodedFragments(maximumPacketLength: Int) throws -> [Data] {
        guard payload.count <= Self.maximumPayloadLength,
              authenticationTag.count == Self.authenticationTagLength else {
            throw VoBLEProtocolError.frameTooLarge
        }
        let capacity = min(255, maximumPacketLength - Self.headerLength)
        guard capacity > 0 else { throw VoBLEProtocolError.invalidLength }
        // CryptoKit can vend Data values backed by slices whose Collection indices
        // do not start at zero. Build a fresh contiguous buffer before fragmenting;
        // subdata(in:) otherwise traps when fed integer offsets as indices.
        var body = Data(capacity: payload.count + authenticationTag.count)
        body.append(payload)
        body.append(authenticationTag)
        let count = max(1, (body.count + capacity - 1) / capacity)
        guard count <= Self.maximumFragmentCount else {
            throw VoBLEProtocolError.tooManyFragments
        }

        return (0..<count).map { index in
            let lower = index * capacity
            let upper = min(body.count, lower + capacity)
            let chunk = body.subdata(in: lower..<upper)
            var encoded = Data([0xa5, 0x5a, 1, 1, flags.rawValue, codec.rawValue, streamID])
            encoded.appendBigEndian(sequence)
            encoded.appendBigEndian(sampleTimestamp)
            encoded.append(UInt8(index))
            encoded.append(UInt8(count))
            encoded.append(UInt8(chunk.count))
            encoded.append(chunk)
            return encoded
        }
    }
}

struct VoBLEAudioHeader: Equatable, Sendable {
    let flags: VoBLEAudioFlags
    let codec: VoBLEAudioCodec
    let streamID: UInt8
    let sequence: UInt32
    let sampleTimestamp: UInt32
    let fragmentIndex: Int
    let fragmentCount: Int
    let fragmentLength: Int

    static func decode(_ data: Data) throws -> (Self, Data) {
        guard data.count >= VoBLEAudioPacket.headerLength else {
            throw VoBLEProtocolError.packetTooSmall
        }
        guard data[0] == 0xa5, data[1] == 0x5a else {
            throw VoBLEProtocolError.invalidMagic
        }
        guard data[2] == 1 else { throw VoBLEProtocolError.unsupportedVersion }
        guard data[3] == 1 else { throw VoBLEProtocolError.invalidType }
        guard let codec = VoBLEAudioCodec(rawValue: data[5]) else {
            throw VoBLEProtocolError.invalidType
        }
        let fragmentIndex = Int(data[15])
        let fragmentCount = Int(data[16])
        let length = Int(data[17])
        guard fragmentCount > 0, fragmentCount <= VoBLEAudioPacket.maximumFragmentCount else {
            throw VoBLEProtocolError.tooManyFragments
        }
        guard fragmentIndex < fragmentCount else { throw VoBLEProtocolError.invalidFragment }
        guard data.count == VoBLEAudioPacket.headerLength + length else {
            throw VoBLEProtocolError.invalidLength
        }
        return (
            Self(
                flags: VoBLEAudioFlags(rawValue: data[4]), codec: codec,
                streamID: data[6], sequence: data.readUInt32(at: 7),
                sampleTimestamp: data.readUInt32(at: 11),
                fragmentIndex: fragmentIndex, fragmentCount: fragmentCount,
                fragmentLength: length
            ),
            data.subdata(in: VoBLEAudioPacket.headerLength..<data.count)
        )
    }
}

struct VoBLEAudioReassembler: Sendable {
    private struct Key: Hashable, Sendable {
        let streamID: UInt8
        let sequence: UInt32
        let sampleTimestamp: UInt32
    }

    private struct Partial: Sendable {
        let firstSeen: Date
        let flags: VoBLEAudioFlags
        let codec: VoBLEAudioCodec
        let fragmentCount: Int
        var fragments: [Int: Data]
    }

    private var partials: [Key: Partial] = [:]
    private var pendingDiscontinuity = false

    mutating func append(_ data: Data, now: Date = Date()) throws -> VoBLEAudioPacket? {
        expire(before: now.addingTimeInterval(-0.2))
        let (header, body) = try VoBLEAudioHeader.decode(data)
        let key = Key(
            streamID: header.streamID,
            sequence: header.sequence,
            sampleTimestamp: header.sampleTimestamp
        )
        var partial = partials[key] ?? Partial(
            firstSeen: now, flags: header.flags, codec: header.codec,
            fragmentCount: header.fragmentCount, fragments: [:]
        )
        guard partial.fragmentCount == header.fragmentCount,
              partial.flags == header.flags,
              partial.codec == header.codec else {
            partials.removeValue(forKey: key)
            pendingDiscontinuity = true
            throw VoBLEProtocolError.inconsistentFrame
        }
        partial.fragments[header.fragmentIndex] = body
        partials[key] = partial
        guard partial.fragments.count == partial.fragmentCount else { return nil }

        var joined = Data()
        for index in 0..<partial.fragmentCount {
            guard let fragment = partial.fragments[index] else { return nil }
            joined.append(fragment)
            guard joined.count <= VoBLEAudioPacket.maximumPayloadLength
                    + VoBLEAudioPacket.authenticationTagLength else {
                partials.removeValue(forKey: key)
                pendingDiscontinuity = true
                throw VoBLEProtocolError.frameTooLarge
            }
        }
        partials.removeValue(forKey: key)
        guard joined.count >= VoBLEAudioPacket.authenticationTagLength else {
            pendingDiscontinuity = true
            throw VoBLEProtocolError.invalidLength
        }
        let payloadEnd = joined.count - VoBLEAudioPacket.authenticationTagLength
        var flags = header.flags
        if pendingDiscontinuity {
            flags.insert(.discontinuity)
            pendingDiscontinuity = false
        }
        return VoBLEAudioPacket(
            flags: flags, codec: header.codec, streamID: header.streamID,
            sequence: header.sequence, sampleTimestamp: header.sampleTimestamp,
            payload: joined.subdata(in: 0..<payloadEnd),
            authenticationTag: joined.subdata(in: payloadEnd..<joined.count)
        )
    }

    private mutating func expire(before cutoff: Date) {
        let expired = partials.filter { $0.value.firstSeen < cutoff }.map(\.key)
        if !expired.isEmpty { pendingDiscontinuity = true }
        expired.forEach { partials.removeValue(forKey: $0) }
    }
}

struct VoBLEControlEnvelope: Equatable, Sendable {
    static let version: UInt8 = 1
    let command: String
    let callID: String
    let generation: UInt64
    let sessionID: Data
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data

    func encoded() throws -> Data {
        let commandData = Data(command.utf8)
        let callIDData = Data(callID.utf8)
        guard sessionID.count <= 255, nonce.count <= 255,
              commandData.count <= 255, callIDData.count <= 255,
              ciphertext.count <= Int(UInt16.max), authenticationTag.count == 16 else {
            throw VoBLEProtocolError.invalidLength
        }
        var result = Data([0xc3, 0x7e, Self.version, 2])
        result.appendBigEndian(generation)
        result.append(UInt8(sessionID.count))
        result.append(UInt8(nonce.count))
        result.append(UInt8(commandData.count))
        result.append(UInt8(callIDData.count))
        result.appendBigEndian(UInt16(ciphertext.count))
        result.append(sessionID)
        result.append(nonce)
        result.append(commandData)
        result.append(callIDData)
        result.append(ciphertext)
        result.append(authenticationTag)
        return result
    }

    static func decode(_ data: Data) throws -> Self {
        let headerLength = 18
        guard data.count >= headerLength + 16 else { throw VoBLEProtocolError.packetTooSmall }
        guard data[0] == 0xc3, data[1] == 0x7e else { throw VoBLEProtocolError.invalidMagic }
        guard data[2] == version else { throw VoBLEProtocolError.unsupportedVersion }
        guard data[3] == 2 else { throw VoBLEProtocolError.invalidType }
        let sessionLength = Int(data[12])
        let nonceLength = Int(data[13])
        let commandLength = Int(data[14])
        let callIDLength = Int(data[15])
        let ciphertextLength = Int(data.readUInt16(at: 16))
        let expected = headerLength + sessionLength + nonceLength + commandLength
            + callIDLength + ciphertextLength + 16
        guard data.count == expected else { throw VoBLEProtocolError.invalidLength }
        var offset = headerLength
        func take(_ count: Int) -> Data {
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        let sessionID = take(sessionLength)
        let nonce = take(nonceLength)
        guard let command = String(data: take(commandLength), encoding: .utf8),
              let callID = String(data: take(callIDLength), encoding: .utf8) else {
            throw VoBLEProtocolError.invalidLength
        }
        let ciphertext = take(ciphertextLength)
        let tag = take(16)
        return Self(
            command: command, callID: callID, generation: data.readUInt64(at: 4),
            sessionID: sessionID, nonce: nonce, ciphertext: ciphertext,
            authenticationTag: tag
        )
    }
}

enum VoBLEMessageType: UInt8, Sendable {
    case pairing = 1
    case control = 2
}

struct VoBLEMessage: Equatable, Sendable {
    let type: VoBLEMessageType
    let messageID: UInt16
    let payload: Data
}

enum VoBLEMessageFragmenter {
    static let headerLength = 8
    static let maximumMessageLength = 4_096

    static func encode(
        _ message: Data,
        type: VoBLEMessageType,
        messageID: UInt16,
        maximumPacketLength: Int
    ) throws -> [Data] {
        guard message.count <= maximumMessageLength else {
            throw VoBLEProtocolError.frameTooLarge
        }
        let capacity = maximumPacketLength - headerLength
        guard capacity > 0 else { throw VoBLEProtocolError.invalidLength }
        let count = max(1, (message.count + capacity - 1) / capacity)
        guard count <= VoBLEAudioPacket.maximumFragmentCount else {
            throw VoBLEProtocolError.tooManyFragments
        }
        return (0..<count).map { index in
            let lower = index * capacity
            let upper = min(message.count, lower + capacity)
            var fragment = Data([
                0xd4, 0x6b, 1, type.rawValue,
                UInt8(truncatingIfNeeded: messageID >> 8),
                UInt8(truncatingIfNeeded: messageID),
                UInt8(index), UInt8(count),
            ])
            if lower < upper { fragment.append(message.subdata(in: lower..<upper)) }
            return fragment
        }
    }
}

struct VoBLEMessageReassembler: Sendable {
    private struct Key: Hashable, Sendable {
        let type: VoBLEMessageType
        let messageID: UInt16
    }
    private struct Partial: Sendable {
        let firstSeen: Date
        let count: Int
        var fragments: [Int: Data]
    }
    private var partials: [Key: Partial] = [:]

    mutating func append(_ fragment: Data, now: Date = Date()) throws -> VoBLEMessage? {
        partials = partials.filter { $0.value.firstSeen >= now.addingTimeInterval(-2) }
        guard fragment.count >= VoBLEMessageFragmenter.headerLength else {
            throw VoBLEProtocolError.packetTooSmall
        }
        guard fragment[0] == 0xd4, fragment[1] == 0x6b else {
            throw VoBLEProtocolError.invalidMagic
        }
        guard fragment[2] == 1 else { throw VoBLEProtocolError.unsupportedVersion }
        guard let type = VoBLEMessageType(rawValue: fragment[3]) else {
            throw VoBLEProtocolError.invalidType
        }
        let messageID = (UInt16(fragment[4]) << 8) | UInt16(fragment[5])
        let index = Int(fragment[6])
        let count = Int(fragment[7])
        guard count > 0, count <= VoBLEAudioPacket.maximumFragmentCount,
              index < count else { throw VoBLEProtocolError.invalidFragment }
        let key = Key(type: type, messageID: messageID)
        var partial = partials[key] ?? Partial(
            firstSeen: now, count: count, fragments: [:])
        guard partial.count == count else {
            partials.removeValue(forKey: key)
            throw VoBLEProtocolError.inconsistentFrame
        }
        partial.fragments[index] = fragment.subdata(
            in: VoBLEMessageFragmenter.headerLength..<fragment.count)
        partials[key] = partial
        guard partial.fragments.count == count else { return nil }
        var payload = Data()
        for part in 0..<count {
            guard let value = partial.fragments[part] else { return nil }
            payload.append(value)
            guard payload.count <= VoBLEMessageFragmenter.maximumMessageLength else {
                partials.removeValue(forKey: key)
                throw VoBLEProtocolError.frameTooLarge
            }
        }
        partials.removeValue(forKey: key)
        return VoBLEMessage(type: type, messageID: messageID, payload: payload)
    }
}

private extension Data {

    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { value, index in
            (value << 8) | UInt64(self[offset + index])
        }
    }
}
