package com.airsim.phonecontrol;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.util.Arrays;
import java.util.Base64;
	import java.security.SecureRandom;

import javax.crypto.Cipher;
import org.bouncycastle.math.ec.rfc7748.X25519;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

public final class PairingCrypto {
    private static final byte[] X25519_PRIVATE_PREFIX = hex("302e020100300506032b656e04220420");
    private static final byte[] X25519_PUBLIC_PREFIX = hex("302a300506032b656e032100");
    private static final byte[] INFO_PREFIX = "AirSIMPair/v1:".getBytes(StandardCharsets.UTF_8);

    private PairingCrypto() {}

	public static final class KeyMaterial {
		public final byte[] privateRaw;
		public final byte[] publicRaw;

		private KeyMaterial(byte[] privateRaw, byte[] publicRaw) {
			this.privateRaw = privateRaw;
			this.publicRaw = publicRaw;
		}
	}

	public static KeyMaterial generateKeyMaterial() throws GeneralSecurityException {
        // Use the bundled lightweight primitive, not the optional Android JCA
        // XDH provider (only standardized on API 33+). No global provider changes.
        byte[] privateKey = new byte[32];
        byte[] publicKey = new byte[32];
        X25519.generatePrivateKey(new SecureRandom(), privateKey);
        X25519.generatePublicKey(privateKey, 0, publicKey, 0);
        return new KeyMaterial(privateKey, publicKey);
	}

    public static byte[] sharedSecret(byte[] privateRaw, byte[] publicRaw) throws GeneralSecurityException {
        if (privateRaw.length != 32 || publicRaw.length != 32) throw new GeneralSecurityException("X25519 key must be 32 bytes");
        byte[] shared = new byte[32];
        if (!X25519.calculateAgreement(privateRaw, 0, publicRaw, 0, shared, 0)) {
            throw new GeneralSecurityException("invalid X25519 peer key");
        }
        return shared;
    }

    public static byte[] deriveKey(byte[] sharedSecret, String sessionID, String code) throws GeneralSecurityException {
        if (sharedSecret.length != 32 || sessionID == null || code == null || !code.matches("[0-9]{6}")) {
            throw new GeneralSecurityException("invalid pairing key inputs");
        }
        byte[] salt = sessionID.getBytes(StandardCharsets.UTF_8);
        byte[] info = concat(INFO_PREFIX, code.getBytes(StandardCharsets.UTF_8));
        Mac hmac = Mac.getInstance("HmacSHA256");
        hmac.init(new SecretKeySpec(salt, "HmacSHA256"));
        byte[] pseudoRandomKey = hmac.doFinal(sharedSecret);
        hmac.init(new SecretKeySpec(pseudoRandomKey, "HmacSHA256"));
        hmac.update(info);
        hmac.update((byte) 1);
        return Arrays.copyOf(hmac.doFinal(), 32);
    }

    public static byte[] open(byte[] combined, byte[] key, String aad) throws GeneralSecurityException {
        if (combined.length < 12 + 16 || key.length != 32) throw new GeneralSecurityException("invalid AES-GCM payload");
        byte[] nonce = Arrays.copyOfRange(combined, 0, 12);
        byte[] ciphertextAndTag = Arrays.copyOfRange(combined, 12, combined.length);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
        return cipher.doFinal(ciphertextAndTag);
    }

	public static byte[] seal(byte[] plaintext, byte[] key, String aad) throws GeneralSecurityException {
		if (key.length != 32) throw new GeneralSecurityException("invalid AES-GCM key");
		byte[] nonce = new byte[12];
		new SecureRandom().nextBytes(nonce);
		Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
		cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
		cipher.updateAAD(aad.getBytes(StandardCharsets.UTF_8));
		return concat(nonce, cipher.doFinal(plaintext));
	}

    public static byte[] rawPublicKey(PublicKey publicKey) throws GeneralSecurityException {
        byte[] encoded = publicKey.getEncoded();
        if (encoded.length != X25519_PUBLIC_PREFIX.length + 32) throw new GeneralSecurityException("unexpected X25519 public key encoding");
        for (int index = 0; index < X25519_PUBLIC_PREFIX.length; index++) {
            if (encoded[index] != X25519_PUBLIC_PREFIX[index]) throw new GeneralSecurityException("unexpected X25519 public key prefix");
        }
        return Arrays.copyOfRange(encoded, X25519_PUBLIC_PREFIX.length, encoded.length);
    }

	public static byte[] rawPrivateKey(PrivateKey privateKey) throws GeneralSecurityException {
		byte[] encoded = privateKey.getEncoded();
		if (encoded.length != X25519_PRIVATE_PREFIX.length + 32) throw new GeneralSecurityException("unexpected X25519 private key encoding");
		for (int index = 0; index < X25519_PRIVATE_PREFIX.length; index++) {
			if (encoded[index] != X25519_PRIVATE_PREFIX[index]) throw new GeneralSecurityException("unexpected X25519 private key prefix");
		}
		return Arrays.copyOfRange(encoded, X25519_PRIVATE_PREFIX.length, encoded.length);
	}

    public static String base64URL(byte[] value) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(value);
    }

    public static byte[] decodeBase64URL(String value) {
        return Base64.getUrlDecoder().decode(value);
    }

    public static byte[] hex(String value) {
        if (value.length() % 2 != 0) throw new IllegalArgumentException("hex length");
        byte[] output = new byte[value.length() / 2];
        for (int index = 0; index < output.length; index++) {
            int high = Character.digit(value.charAt(index * 2), 16);
            int low = Character.digit(value.charAt(index * 2 + 1), 16);
            if (high < 0 || low < 0) throw new IllegalArgumentException("invalid hex");
            output[index] = (byte) ((high << 4) | low);
        }
        return output;
    }

    public static String hex(byte[] value) {
        StringBuilder output = new StringBuilder(value.length * 2);
        for (byte item : value) output.append(String.format("%02x", item & 0xff));
        return output.toString();
    }

    private static byte[] concat(byte[] first, byte[] second) {
        ByteArrayOutputStream output = new ByteArrayOutputStream(first.length + second.length);
        output.write(first, 0, first.length);
        output.write(second, 0, second.length);
        return output.toByteArray();
    }
}
