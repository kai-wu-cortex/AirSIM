package com.airsim.phonecontrol;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Locale;
import java.util.UUID;

public final class PairingSession {
    public static final long LIFETIME_MILLIS = 120_000L;

    private final String id;
    private final String code;
    private final long expiresAtMillis;
    private final byte[] privateKey;
    private final byte[] publicKey;
    private boolean used;

    private PairingSession(String id, String code, long expiresAtMillis, byte[] privateKey, byte[] publicKey) {
        this.id = id;
        this.code = code;
        this.expiresAtMillis = expiresAtMillis;
        this.privateKey = privateKey;
        this.publicKey = publicKey;
    }

    public static PairingSession create(long nowMillis) throws GeneralSecurityException {
        SecureRandom random = new SecureRandom();
        PairingCrypto.KeyMaterial keys = PairingCrypto.generateKeyMaterial();
        String code = String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000));
        return new PairingSession(UUID.randomUUID().toString(), code, nowMillis + LIFETIME_MILLIS,
                keys.privateRaw, keys.publicRaw);
    }

    public String id() { return id; }
    public String code() { return code; }
    public long expiresAtMillis() { return expiresAtMillis; }
    public byte[] publicKey() { return publicKey.clone(); }

    public synchronized byte[] claim(byte[] clientPublicKey, byte[] sealedRegistration, long nowMillis)
            throws GeneralSecurityException {
        if (used) throw new GeneralSecurityException("pairing session already used");
        if (nowMillis > expiresAtMillis) throw new GeneralSecurityException("pairing session expired");
        byte[] shared = PairingCrypto.sharedSecret(privateKey, clientPublicKey);
        byte[] key = PairingCrypto.deriveKey(shared, id, code);
        byte[] plaintext = PairingCrypto.open(sealedRegistration, key, id);
        used = true;
        return plaintext;
    }
}
