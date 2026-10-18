package com.airsim.phonecontrol.voble;

import com.airsim.phonecontrol.PairingCrypto;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class VoBLEPairingManager {
    private static final byte[] PREFIX = "AirSIM/VoBLE/v1/".getBytes(StandardCharsets.UTF_8);
    private static final long CHALLENGE_LIFETIME_MILLIS = 120_000L;

    public record Transcript(
            String androidIdentity,
            byte[] androidPublicKey,
            byte[] iphonePublicKey,
            byte[] androidNonce,
            byte[] iphoneNonce) {
        public Transcript {
            androidPublicKey = androidPublicKey.clone();
            iphonePublicKey = iphonePublicKey.clone();
            androidNonce = androidNonce.clone();
            iphoneNonce = iphoneNonce.clone();
        }

        public byte[] encoded() {
            if (androidIdentity == null || androidIdentity.isEmpty()
                    || androidPublicKey.length != 32 || iphonePublicKey.length != 32
                    || androidNonce.length != 32 || iphoneNonce.length != 32) {
                throw new IllegalArgumentException("invalid pairing transcript");
            }
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            writeField(output, new byte[]{1});
            writeField(output, androidIdentity.getBytes(StandardCharsets.UTF_8));
            writeField(output, androidPublicKey);
            writeField(output, iphonePublicKey);
            writeField(output, androidNonce);
            writeField(output, iphoneNonce);
            return output.toByteArray();
        }

        @Override public String toString() {
            return "Transcript(identity=" + androidIdentity + ",keys=redacted,nonces=redacted)";
        }
    }

    public record PairingMaterial(byte[] pairingKey, String sas) {
        public PairingMaterial { pairingKey = pairingKey.clone(); }
        @Override public byte[] pairingKey() { return pairingKey.clone(); }
        @Override public String toString() { return "PairingMaterial(sas=redacted,key=redacted)"; }
    }

    public record SessionKeys(byte[] control, byte[] media, byte[] reconnect) {
        public SessionKeys {
            control = control.clone();
            media = media.clone();
            reconnect = reconnect.clone();
        }
        @Override public byte[] control() { return control.clone(); }
        @Override public byte[] media() { return media.clone(); }
        @Override public byte[] reconnect() { return reconnect.clone(); }
        @Override public String toString() { return "SessionKeys(redacted)"; }
    }

    public record Challenge(
            String id, String androidIdentity, byte[] androidPublicKey,
            byte[] androidNonce, long expiresAtMillis) {
        public Challenge {
            androidPublicKey = androidPublicKey.clone();
            androidNonce = androidNonce.clone();
        }
        @Override public String toString() {
            return "Challenge(id=" + id + ",identity=" + androidIdentity
                    + ",key=redacted,nonce=redacted,expires=" + expiresAtMillis + ")";
        }
    }

    private static final class Pending {
        final Challenge challenge;
        final byte[] privateKey;
        Pending(Challenge challenge, byte[] privateKey) {
            this.challenge = challenge;
            this.privateKey = privateKey;
        }
    }

    private final SecureRandom random = new SecureRandom();
    private final VoBLECredentialStore credentials;
    private final Map<String, Pending> pending = new HashMap<>();
    private final Map<String, VoBLEReplayWindow> replay = new HashMap<>();

    public VoBLEPairingManager(VoBLECredentialStore credentials) {
        this.credentials = credentials;
    }

    public synchronized Challenge begin(String androidIdentity, long nowMillis)
            throws GeneralSecurityException {
        PairingCrypto.KeyMaterial keys = PairingCrypto.generateKeyMaterial();
        byte[] nonce = new byte[32];
        random.nextBytes(nonce);
        Challenge challenge = new Challenge(
                UUID.randomUUID().toString(), androidIdentity, keys.publicRaw, nonce,
                nowMillis + CHALLENGE_LIFETIME_MILLIS);
        pending.put(challenge.id, new Pending(challenge, keys.privateRaw));
        return challenge;
    }

    public synchronized PairingMaterial confirm(
            String challengeId, byte[] iphonePublicKey, byte[] iphoneNonce,
            String confirmedSas, long nowMillis) throws GeneralSecurityException {
        Pending value = pending.remove(challengeId);
        if (value == null) throw new GeneralSecurityException("unknown pairing challenge");
        try {
            if (nowMillis > value.challenge.expiresAtMillis) {
                throw new GeneralSecurityException("pairing challenge expired");
            }
            Transcript transcript = new Transcript(
                    value.challenge.androidIdentity, value.challenge.androidPublicKey,
                    iphonePublicKey, value.challenge.androidNonce, iphoneNonce);
            PairingMaterial material = derivePairing(value.privateKey, iphonePublicKey, transcript);
            byte[] existing = credentials.load(value.challenge.androidIdentity);
            if (existing != null) {
                Arrays.fill(existing, (byte) 0);
                throw new GeneralSecurityException("peer is already paired; authenticated reconnect required");
            }
            if (!constantTimeEquals(material.sas, confirmedSas)) {
                throw new GeneralSecurityException("pairing confirmation failed");
            }
            credentials.save(value.challenge.androidIdentity, material.pairingKey);
            replay.put(value.challenge.androidIdentity, new VoBLEReplayWindow(30_000L, 256));
            return material;
        } finally {
            Arrays.fill(value.privateKey, (byte) 0);
        }
    }

    public synchronized PairingMaterial preview(
            String challengeId, byte[] iphonePublicKey, byte[] iphoneNonce,
            long nowMillis) throws GeneralSecurityException {
        Pending value = pending.get(challengeId);
        if (value == null) throw new GeneralSecurityException("unknown pairing challenge");
        if (nowMillis > value.challenge.expiresAtMillis) {
            pending.remove(challengeId);
            Arrays.fill(value.privateKey, (byte) 0);
            throw new GeneralSecurityException("pairing challenge expired");
        }
        Transcript transcript = new Transcript(
                value.challenge.androidIdentity, value.challenge.androidPublicKey,
                iphonePublicKey, value.challenge.androidNonce, iphoneNonce);
        return derivePairing(value.privateKey, iphonePublicKey, transcript);
    }

    public synchronized PairingMaterial confirmReconnect(
            String challengeId, byte[] iphonePublicKey, byte[] iphoneNonce,
            byte[] reconnectTag, long nowMillis) throws GeneralSecurityException {
        Pending value = pending.remove(challengeId);
        if (value == null) throw new GeneralSecurityException("unknown pairing challenge");
        try {
            if (nowMillis > value.challenge.expiresAtMillis) {
                throw new GeneralSecurityException("pairing challenge expired");
            }
            Transcript transcript = new Transcript(
                    value.challenge.androidIdentity, value.challenge.androidPublicKey,
                    iphonePublicKey, value.challenge.androidNonce, iphoneNonce);
            byte[] existing = credentials.load(value.challenge.androidIdentity);
            if (existing == null) throw new GeneralSecurityException("peer is not paired");
            try {
                byte[] expected = reconnectTag(existing, transcript);
                if (reconnectTag == null || !MessageDigest.isEqual(expected, reconnectTag)) {
                    throw new GeneralSecurityException("reconnect authentication failed");
                }
            } finally {
                Arrays.fill(existing, (byte) 0);
            }
            PairingMaterial material = derivePairing(value.privateKey, iphonePublicKey, transcript);
            credentials.save(value.challenge.androidIdentity, material.pairingKey);
            replay.put(value.challenge.androidIdentity, new VoBLEReplayWindow(30_000L, 256));
            return material;
        } finally {
            Arrays.fill(value.privateKey, (byte) 0);
        }
    }

    public static byte[] reconnectTag(byte[] pairingKey, Transcript transcript)
            throws GeneralSecurityException {
        return authenticationTag(
                concat(concat(PREFIX, utf8("reconnect")), transcript.encoded()), pairingKey);
    }

    public static byte[] confirmationTag(byte[] pairingKey, String challengeId)
            throws GeneralSecurityException {
        if (challengeId == null || challengeId.isEmpty()) {
            throw new GeneralSecurityException("invalid pairing confirmation");
        }
        return authenticationTag(
                concat(concat(PREFIX, utf8("ready")), utf8(challengeId)), pairingKey);
    }

    public synchronized boolean authenticate(
            String identity, byte[] sessionId, String callId, long generation,
            byte[] nonce, long timestampMillis, byte[] message, byte[] tag, long nowMillis)
            throws GeneralSecurityException {
        byte[] pairingKey = credentials.load(identity);
        if (pairingKey == null) return false;
        try {
            VoBLEReplayWindow window = replay.computeIfAbsent(
                    identity, ignored -> new VoBLEReplayWindow(30_000L, 256));
            SessionKeys keys = deriveSessionKeys(pairingKey, sessionId, callId, generation);
            byte[] expected = authenticationTag(
                    authenticationMessage(nonce, timestampMillis, message), keys.control);
            if (tag == null || !MessageDigest.isEqual(tag, expected)) return false;
            return window.accept(nonce, timestampMillis, nowMillis);
        } finally {
            Arrays.fill(pairingKey, (byte) 0);
        }
    }

    public synchronized void revoke(String identity) {
        credentials.revoke(identity);
        VoBLEReplayWindow window = replay.remove(identity);
        if (window != null) window.revoke();
    }

    public static byte[] publicKey(byte[] privateKey) throws GeneralSecurityException {
        byte[] basePoint = new byte[32];
        basePoint[0] = 9;
        return PairingCrypto.sharedSecret(privateKey, basePoint);
    }

    public static PairingMaterial derivePairing(
            byte[] privateKey, byte[] peerPublicKey, Transcript transcript)
            throws GeneralSecurityException {
        byte[] encoded = transcript.encoded();
        byte[] shared = PairingCrypto.sharedSecret(privateKey, peerPublicKey);
        byte[] salt = MessageDigest.getInstance("SHA-256").digest(encoded);
        byte[] pairingKey = hkdf(shared, salt, concat(PREFIX, utf8("pairing")), 32);
        byte[] digest = hmac(pairingKey, concat(concat(PREFIX, utf8("sas")), encoded));
        long sasValue = ((digest[0] & 0xffL) << 24) | ((digest[1] & 0xffL) << 16)
                | ((digest[2] & 0xffL) << 8) | (digest[3] & 0xffL);
        return new PairingMaterial(pairingKey,
                String.format(Locale.ROOT, "%06d", sasValue % 1_000_000L));
    }

    public static SessionKeys deriveSessionKeys(
            byte[] pairingKey, byte[] sessionId, String callId, long generation)
            throws GeneralSecurityException {
        if (pairingKey == null || pairingKey.length != 32 || sessionId == null
                || sessionId.length == 0 || callId == null) {
            throw new GeneralSecurityException("invalid session key inputs");
        }
        ByteArrayOutputStream context = new ByteArrayOutputStream();
        writeField(context, sessionId);
        writeField(context, callId.getBytes(StandardCharsets.UTF_8));
        byte[] generationBytes = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(generation).array();
        context.write(generationBytes, 0, generationBytes.length);
        byte[] salt = MessageDigest.getInstance("SHA-256").digest(context.toByteArray());
        return new SessionKeys(
                hkdf(pairingKey, salt, concat(PREFIX, utf8("control")), 32),
                hkdf(pairingKey, salt, concat(PREFIX, utf8("media")), 32),
                hkdf(pairingKey, salt, concat(PREFIX, utf8("reconnect")), 32));
    }

    public static byte[] authenticationTag(byte[] message, byte[] key)
            throws GeneralSecurityException {
        return Arrays.copyOf(hmac(key, message), 16);
    }

    public static boolean authenticateTag(byte[] message, byte[] tag, byte[] key) {
        try {
            return tag != null && MessageDigest.isEqual(tag, authenticationTag(message, key));
        } catch (GeneralSecurityException | RuntimeException error) {
            return false;
        }
    }

    public byte[] signSessionMessage(
            String identity, byte[] sessionId, String callId, long generation,
            byte[] nonce, long timestampMillis, byte[] message) throws GeneralSecurityException {
        byte[] pairingKey = credentials.load(identity);
        if (pairingKey == null) throw new GeneralSecurityException("peer is not paired");
        try {
            SessionKeys keys = deriveSessionKeys(pairingKey, sessionId, callId, generation);
            return authenticationTag(authenticationMessage(nonce, timestampMillis, message), keys.control);
        } finally {
            Arrays.fill(pairingKey, (byte) 0);
        }
    }

    public SessionKeys storedSessionKeys(
            String identity, byte[] sessionId, String callId, long generation)
            throws GeneralSecurityException {
        byte[] pairingKey = credentials.load(identity);
        if (pairingKey == null) throw new GeneralSecurityException("peer is not paired");
        try {
            return deriveSessionKeys(pairingKey, sessionId, callId, generation);
        } finally {
            Arrays.fill(pairingKey, (byte) 0);
        }
    }

    private static byte[] authenticationMessage(byte[] nonce, long timestamp, byte[] message) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        writeField(output, nonce);
        byte[] timestampBytes = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(timestamp).array();
        output.write(timestampBytes, 0, timestampBytes.length);
        output.write(message, 0, message.length);
        return output.toByteArray();
    }

    private static byte[] hkdf(byte[] input, byte[] salt, byte[] info, int length)
            throws GeneralSecurityException {
        byte[] pseudoRandomKey = hmac(salt, input);
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] previous = new byte[0];
        for (int counter = 1; output.size() < length; counter++) {
            previous = hmac(pseudoRandomKey, concat(concat(previous, info), new byte[]{(byte) counter}));
            output.write(previous, 0, previous.length);
        }
        return Arrays.copyOf(output.toByteArray(), length);
    }

    private static byte[] hmac(byte[] key, byte[] value) throws GeneralSecurityException {
        Mac hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(key, "HmacSHA256"));
        return hmac.doFinal(value);
    }

    private static void writeField(ByteArrayOutputStream output, byte[] value) {
        if (value.length > 0xffff) throw new IllegalArgumentException("transcript field too large");
        output.write((value.length >>> 8) & 0xff);
        output.write(value.length & 0xff);
        output.write(value, 0, value.length);
    }

    private static boolean constantTimeEquals(String first, String second) {
        if (first == null || second == null) return false;
        return MessageDigest.isEqual(first.getBytes(StandardCharsets.UTF_8),
                second.getBytes(StandardCharsets.UTF_8));
    }

    private static byte[] utf8(String value) { return value.getBytes(StandardCharsets.UTF_8); }

    private static byte[] concat(byte[] first, byte[] second) {
        byte[] result = Arrays.copyOf(first, first.length + second.length);
        System.arraycopy(second, 0, result, first.length, second.length);
        return result;
    }
}
