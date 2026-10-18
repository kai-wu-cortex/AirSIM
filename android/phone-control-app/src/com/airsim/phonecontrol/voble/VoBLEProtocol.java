package com.airsim.phonecontrol.voble;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

public final class VoBLEProtocol {
    public static final int VERSION = 1;
    public static final int TYPE_AUDIO = 1;
    public static final int MESSAGE_PAIRING = 1;
    public static final int MESSAGE_CONTROL = 2;
    public static final int MESSAGE_HEADER_LENGTH = 8;
    public static final int MAX_MESSAGE_LENGTH = 4096;
    public static final int CODEC_G711_MULAW = 1;
    public static final int FLAG_DISCONTINUITY = 1 << 3;
    public static final int AUDIO_HEADER_LENGTH = 18;
    public static final int AUTH_TAG_LENGTH = 16;
    public static final int MAX_FRAGMENT_COUNT = 64;
    public static final int MAX_PAYLOAD_LENGTH = 512;

    private VoBLEProtocol() {}

    public record ControlEnvelope(
            String command,
            String callId,
            long generation,
            byte[] sessionId,
            byte[] nonce,
            byte[] ciphertext,
            byte[] authenticationTag) {
        public ControlEnvelope {
            sessionId = sessionId.clone();
            nonce = nonce.clone();
            ciphertext = ciphertext.clone();
            authenticationTag = authenticationTag.clone();
        }

        @Override public byte[] sessionId() { return sessionId.clone(); }
        @Override public byte[] nonce() { return nonce.clone(); }
        @Override public byte[] ciphertext() { return ciphertext.clone(); }
        @Override public byte[] authenticationTag() { return authenticationTag.clone(); }

        @Override public boolean equals(Object value) {
            if (!(value instanceof ControlEnvelope other)) return false;
            return generation == other.generation && command.equals(other.command)
                    && callId.equals(other.callId) && Arrays.equals(sessionId, other.sessionId)
                    && Arrays.equals(nonce, other.nonce) && Arrays.equals(ciphertext, other.ciphertext)
                    && Arrays.equals(authenticationTag, other.authenticationTag);
        }

        @Override public int hashCode() {
            int result = Objects.hash(command, callId, generation);
            result = 31 * result + Arrays.hashCode(sessionId);
            result = 31 * result + Arrays.hashCode(nonce);
            result = 31 * result + Arrays.hashCode(ciphertext);
            return 31 * result + Arrays.hashCode(authenticationTag);
        }
    }

    public record AudioHeader(
            int flags,
            int codec,
            int streamId,
            long sequence,
            long sampleTimestamp,
            int fragmentIndex,
            int fragmentCount,
            int fragmentLength) {}

    public record Message(int type, int messageId, byte[] payload) {
        public Message { payload = payload.clone(); }
        @Override public byte[] payload() { return payload.clone(); }
    }

    public static List<byte[]> encodeMessageFragments(
            byte[] message, int maximumPacketLength, int type, int messageId) {
        if (message == null || message.length > MAX_MESSAGE_LENGTH
                || (type != MESSAGE_PAIRING && type != MESSAGE_CONTROL)
                || (messageId & ~0xffff) != 0) {
            throw new IllegalArgumentException("invalid message fragment input");
        }
        int capacity = maximumPacketLength - MESSAGE_HEADER_LENGTH;
        if (capacity <= 0 || capacity > 0xffff) {
            throw new IllegalArgumentException("packet length cannot hold message header");
        }
        int count = Math.max(1, (message.length + capacity - 1) / capacity);
        if (count > MAX_FRAGMENT_COUNT) throw new IllegalArgumentException("too many fragments");
        List<byte[]> result = new ArrayList<>(count);
        for (int index = 0; index < count; index++) {
            int offset = index * capacity;
            int length = Math.min(capacity, message.length - offset);
            byte[] fragment = new byte[MESSAGE_HEADER_LENGTH + length];
            fragment[0] = (byte) 0xd4;
            fragment[1] = 0x6b;
            fragment[2] = VERSION;
            fragment[3] = (byte) type;
            fragment[4] = (byte) (messageId >>> 8);
            fragment[5] = (byte) messageId;
            fragment[6] = (byte) index;
            fragment[7] = (byte) count;
            System.arraycopy(message, offset, fragment, MESSAGE_HEADER_LENGTH, length);
            result.add(fragment);
        }
        return result;
    }

    public static final class MessageReassembler {
        private record Key(int type, int messageId) {}
        private static final class PartialMessage {
            final long firstSeenMillis;
            final int fragmentCount;
            final Map<Integer, byte[]> fragments = new HashMap<>();
            PartialMessage(long firstSeenMillis, int fragmentCount) {
                this.firstSeenMillis = firstSeenMillis;
                this.fragmentCount = fragmentCount;
            }
        }
        private final Map<Key, PartialMessage> partials = new HashMap<>();

        public synchronized Message append(byte[] fragment, long nowMillis) {
            partials.entrySet().removeIf(entry -> entry.getValue().firstSeenMillis < nowMillis - 2_000L);
            if (fragment == null || fragment.length < MESSAGE_HEADER_LENGTH
                    || (fragment[0] & 0xff) != 0xd4 || (fragment[1] & 0xff) != 0x6b
                    || (fragment[2] & 0xff) != VERSION) {
                throw new IllegalArgumentException("invalid message fragment");
            }
            int type = fragment[3] & 0xff;
            int messageId = ((fragment[4] & 0xff) << 8) | (fragment[5] & 0xff);
            int index = fragment[6] & 0xff;
            int count = fragment[7] & 0xff;
            if ((type != MESSAGE_PAIRING && type != MESSAGE_CONTROL)
                    || count == 0 || count > MAX_FRAGMENT_COUNT || index >= count) {
                throw new IllegalArgumentException("invalid message fragment header");
            }
            Key key = new Key(type, messageId);
            PartialMessage partial = partials.computeIfAbsent(
                    key, ignored -> new PartialMessage(nowMillis, count));
            if (partial.fragmentCount != count) {
                partials.remove(key);
                throw new IllegalArgumentException("inconsistent message fragments");
            }
            partial.fragments.put(index,
                    Arrays.copyOfRange(fragment, MESSAGE_HEADER_LENGTH, fragment.length));
            if (partial.fragments.size() != count) return null;
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            for (int part = 0; part < count; part++) {
                byte[] value = partial.fragments.get(part);
                if (value == null) return null;
                output.write(value, 0, value.length);
                if (output.size() > MAX_MESSAGE_LENGTH) {
                    partials.remove(key);
                    throw new IllegalArgumentException("message is too large");
                }
            }
            partials.remove(key);
            return new Message(type, messageId, output.toByteArray());
        }
    }

    public record AudioPacket(
            int flags,
            int codec,
            int streamId,
            long sequence,
            long sampleTimestamp,
            byte[] payload,
            byte[] authenticationTag) {
        public AudioPacket {
            if ((flags & ~0xff) != 0 || (codec & ~0xff) != 0 || (streamId & ~0xff) != 0
                    || (sequence & ~0xffff_ffffL) != 0
                    || (sampleTimestamp & ~0xffff_ffffL) != 0) {
                throw new IllegalArgumentException("audio header field is out of range");
            }
            payload = payload.clone();
            authenticationTag = authenticationTag.clone();
        }

        @Override public byte[] payload() { return payload.clone(); }
        @Override public byte[] authenticationTag() { return authenticationTag.clone(); }

        @Override public boolean equals(Object value) {
            if (!(value instanceof AudioPacket other)) return false;
            return flags == other.flags && codec == other.codec && streamId == other.streamId
                    && sequence == other.sequence && sampleTimestamp == other.sampleTimestamp
                    && Arrays.equals(payload, other.payload)
                    && Arrays.equals(authenticationTag, other.authenticationTag);
        }

        @Override public int hashCode() {
            int result = Objects.hash(flags, codec, streamId, sequence, sampleTimestamp);
            result = 31 * result + Arrays.hashCode(payload);
            return 31 * result + Arrays.hashCode(authenticationTag);
        }
    }

    public static List<byte[]> encodeAudioFragments(AudioPacket packet, int maximumPacketLength) {
        Objects.requireNonNull(packet, "packet");
        if (packet.payload.length > MAX_PAYLOAD_LENGTH
                || packet.authenticationTag.length != AUTH_TAG_LENGTH) {
            throw new IllegalArgumentException("invalid audio payload or authentication tag");
        }
        int capacity = Math.min(255, maximumPacketLength - AUDIO_HEADER_LENGTH);
        if (capacity <= 0) throw new IllegalArgumentException("packet length cannot hold header");
        byte[] body = new byte[packet.payload.length + packet.authenticationTag.length];
        System.arraycopy(packet.payload, 0, body, 0, packet.payload.length);
        System.arraycopy(packet.authenticationTag, 0, body, packet.payload.length,
                packet.authenticationTag.length);
        int count = Math.max(1, (body.length + capacity - 1) / capacity);
        if (count > MAX_FRAGMENT_COUNT) throw new IllegalArgumentException("too many fragments");

        List<byte[]> result = new ArrayList<>(count);
        for (int index = 0; index < count; index++) {
            int offset = index * capacity;
            int length = Math.min(capacity, body.length - offset);
            byte[] encoded = new byte[AUDIO_HEADER_LENGTH + length];
            encoded[0] = (byte) 0xa5;
            encoded[1] = 0x5a;
            encoded[2] = VERSION;
            encoded[3] = TYPE_AUDIO;
            encoded[4] = (byte) packet.flags;
            encoded[5] = (byte) packet.codec;
            encoded[6] = (byte) packet.streamId;
            putUInt32(encoded, 7, packet.sequence);
            putUInt32(encoded, 11, packet.sampleTimestamp);
            encoded[15] = (byte) index;
            encoded[16] = (byte) count;
            encoded[17] = (byte) length;
            System.arraycopy(body, offset, encoded, AUDIO_HEADER_LENGTH, length);
            result.add(encoded);
        }
        return result;
    }

    public static byte[] encodeControl(ControlEnvelope envelope) {
        byte[] command = envelope.command.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] callId = envelope.callId.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        if (envelope.sessionId.length > 255 || envelope.nonce.length > 255
                || command.length > 255 || callId.length > 255
                || envelope.ciphertext.length > 0xffff
                || envelope.authenticationTag.length != AUTH_TAG_LENGTH) {
            throw new IllegalArgumentException("invalid control envelope length");
        }
        int headerLength = 18;
        byte[] result = new byte[headerLength + envelope.sessionId.length + envelope.nonce.length
                + command.length + callId.length + envelope.ciphertext.length + AUTH_TAG_LENGTH];
        result[0] = (byte) 0xc3;
        result[1] = 0x7e;
        result[2] = VERSION;
        result[3] = 2;
        putUInt64(result, 4, envelope.generation);
        result[12] = (byte) envelope.sessionId.length;
        result[13] = (byte) envelope.nonce.length;
        result[14] = (byte) command.length;
        result[15] = (byte) callId.length;
        result[16] = (byte) (envelope.ciphertext.length >>> 8);
        result[17] = (byte) envelope.ciphertext.length;
        int offset = headerLength;
        for (byte[] part : new byte[][]{
                envelope.sessionId, envelope.nonce, command, callId,
                envelope.ciphertext, envelope.authenticationTag}) {
            System.arraycopy(part, 0, result, offset, part.length);
            offset += part.length;
        }
        return result;
    }

    public static ControlEnvelope decodeControl(byte[] packet) {
        int headerLength = 18;
        if (packet == null || packet.length < headerLength + AUTH_TAG_LENGTH) {
            throw new IllegalArgumentException("control packet is too small");
        }
        if ((packet[0] & 0xff) != 0xc3 || (packet[1] & 0xff) != 0x7e) {
            throw new IllegalArgumentException("invalid control magic");
        }
        if ((packet[2] & 0xff) != VERSION) throw new IllegalArgumentException("unsupported version");
        if ((packet[3] & 0xff) != 2) throw new IllegalArgumentException("invalid packet type");
        int sessionLength = packet[12] & 0xff;
        int nonceLength = packet[13] & 0xff;
        int commandLength = packet[14] & 0xff;
        int callIdLength = packet[15] & 0xff;
        int ciphertextLength = ((packet[16] & 0xff) << 8) | (packet[17] & 0xff);
        int expected = headerLength + sessionLength + nonceLength + commandLength
                + callIdLength + ciphertextLength + AUTH_TAG_LENGTH;
        if (packet.length != expected) throw new IllegalArgumentException("invalid control length");
        int offset = headerLength;
        byte[] sessionId = Arrays.copyOfRange(packet, offset, offset += sessionLength);
        byte[] nonce = Arrays.copyOfRange(packet, offset, offset += nonceLength);
        String command = new String(packet, offset, commandLength, java.nio.charset.StandardCharsets.UTF_8);
        offset += commandLength;
        String callId = new String(packet, offset, callIdLength, java.nio.charset.StandardCharsets.UTF_8);
        offset += callIdLength;
        byte[] ciphertext = Arrays.copyOfRange(packet, offset, offset += ciphertextLength);
        byte[] tag = Arrays.copyOfRange(packet, offset, offset + AUTH_TAG_LENGTH);
        return new ControlEnvelope(command, callId, readUInt64(packet, 4),
                sessionId, nonce, ciphertext, tag);
    }

    public static AudioHeader decodeAudioHeader(byte[] packet) {
        if (packet == null || packet.length < AUDIO_HEADER_LENGTH) {
            throw new IllegalArgumentException("audio packet is too small");
        }
        if ((packet[0] & 0xff) != 0xa5 || (packet[1] & 0xff) != 0x5a) {
            throw new IllegalArgumentException("invalid audio magic");
        }
        if ((packet[2] & 0xff) != VERSION) throw new IllegalArgumentException("unsupported version");
        if ((packet[3] & 0xff) != TYPE_AUDIO) throw new IllegalArgumentException("invalid packet type");
        int codec = packet[5] & 0xff;
        if (codec != CODEC_G711_MULAW) throw new IllegalArgumentException("unsupported codec");
        int index = packet[15] & 0xff;
        int count = packet[16] & 0xff;
        int length = packet[17] & 0xff;
        if (count == 0 || count > MAX_FRAGMENT_COUNT) {
            throw new IllegalArgumentException("invalid fragment count");
        }
        if (index >= count) throw new IllegalArgumentException("invalid fragment index");
        if (packet.length != AUDIO_HEADER_LENGTH + length) {
            throw new IllegalArgumentException("invalid fragment length");
        }
        return new AudioHeader(
                packet[4] & 0xff, codec, packet[6] & 0xff,
                readUInt32(packet, 7), readUInt32(packet, 11), index, count, length);
    }

    public static final class AudioReassembler {
        private record Key(int streamId, long sequence, long timestamp) {}
        private static final class Partial {
            final long firstSeenMillis;
            final AudioHeader header;
            final Map<Integer, byte[]> fragments = new HashMap<>();
            Partial(long firstSeenMillis, AudioHeader header) {
                this.firstSeenMillis = firstSeenMillis;
                this.header = header;
            }
        }

        private final Map<Key, Partial> partials = new HashMap<>();
        private boolean pendingDiscontinuity;

        public AudioPacket append(byte[] packet, long nowMillis) {
            expire(nowMillis - 200L);
            AudioHeader header = decodeAudioHeader(packet);
            Key key = new Key(header.streamId, header.sequence, header.sampleTimestamp);
            Partial partial = partials.computeIfAbsent(key, ignored -> new Partial(nowMillis, header));
            if (partial.header.flags != header.flags || partial.header.codec != header.codec
                    || partial.header.fragmentCount != header.fragmentCount) {
                partials.remove(key);
                pendingDiscontinuity = true;
                throw new IllegalArgumentException("inconsistent frame fragments");
            }
            partial.fragments.put(header.fragmentIndex,
                    Arrays.copyOfRange(packet, AUDIO_HEADER_LENGTH, packet.length));
            if (partial.fragments.size() != header.fragmentCount) return null;

            ByteArrayOutputStream body = new ByteArrayOutputStream();
            for (int index = 0; index < header.fragmentCount; index++) {
                byte[] fragment = partial.fragments.get(index);
                if (fragment == null) return null;
                body.write(fragment, 0, fragment.length);
                if (body.size() > MAX_PAYLOAD_LENGTH + AUTH_TAG_LENGTH) {
                    partials.remove(key);
                    pendingDiscontinuity = true;
                    throw new IllegalArgumentException("audio frame is too large");
                }
            }
            partials.remove(key);
            byte[] joined = body.toByteArray();
            if (joined.length < AUTH_TAG_LENGTH) {
                pendingDiscontinuity = true;
                throw new IllegalArgumentException("missing authentication tag");
            }
            int payloadLength = joined.length - AUTH_TAG_LENGTH;
            int flags = header.flags;
            if (pendingDiscontinuity) {
                flags |= FLAG_DISCONTINUITY;
                pendingDiscontinuity = false;
            }
            return new AudioPacket(
                    flags, header.codec, header.streamId, header.sequence, header.sampleTimestamp,
                    Arrays.copyOfRange(joined, 0, payloadLength),
                    Arrays.copyOfRange(joined, payloadLength, joined.length));
        }

        private void expire(long cutoffMillis) {
            boolean removed = partials.entrySet().removeIf(
                    entry -> entry.getValue().firstSeenMillis < cutoffMillis);
            if (removed) pendingDiscontinuity = true;
        }
    }

    private static void putUInt32(byte[] target, int offset, long value) {
        target[offset] = (byte) (value >>> 24);
        target[offset + 1] = (byte) (value >>> 16);
        target[offset + 2] = (byte) (value >>> 8);
        target[offset + 3] = (byte) value;
    }

    private static void putUInt64(byte[] target, int offset, long value) {
        for (int index = 7; index >= 0; index--) {
            target[offset + index] = (byte) value;
            value >>>= 8;
        }
    }

    private static long readUInt32(byte[] source, int offset) {
        return ((long) (source[offset] & 0xff) << 24)
                | ((long) (source[offset + 1] & 0xff) << 16)
                | ((long) (source[offset + 2] & 0xff) << 8)
                | (source[offset + 3] & 0xffL);
    }

    private static long readUInt64(byte[] source, int offset) {
        long value = 0;
        for (int index = 0; index < 8; index++) {
            value = (value << 8) | (source[offset + index] & 0xffL);
        }
        return value;
    }
}
