package com.airsim.phonecontrol;

import java.security.Provider;
import java.security.Security;
import java.util.Arrays;

/** Runs the real pairing code without a JCA XDH implementation (Android 10–12). */
public final class PairingCryptoCompatibilityTests {
    public static void main(String[] args) throws Exception {
        for (Provider provider : Security.getProviders()) {
            if (provider.getService("KeyPairGenerator", "XDH") != null
                    || provider.getService("KeyAgreement", "XDH") != null) {
                Security.removeProvider(provider.getName());
            }
        }
        try {
            var first = PairingCrypto.generateKeyMaterial();
            var second = PairingCrypto.generateKeyMaterial();
            check(first.publicRaw.length == 32 && first.privateRaw.length == 32, "wire key length changed");
            check(!Arrays.equals(first.publicRaw, second.publicRaw), "keys are not fresh");
            check(Arrays.equals(PairingCrypto.sharedSecret(first.privateRaw, second.publicRaw),
                    PairingCrypto.sharedSecret(second.privateRaw, first.publicRaw)), "two-way agreement failed");
            byte[] alice = PairingCrypto.hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
            byte[] bob = PairingCrypto.hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
            check(PairingCrypto.hex(PairingCrypto.sharedSecret(alice, bob)).equals(
                    "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"), "RFC7748 vector failed");
            boolean rejected = false;
            try { PairingCrypto.sharedSecret(alice, new byte[32]); }
            catch (java.security.GeneralSecurityException expected) { rejected = true; }
            check(rejected, "low-order all-zero peer accepted");
        } catch (java.security.NoSuchAlgorithmException error) {
            throw new AssertionError("Pairing must work when Android exposes no XDH Provider", error);
        }
        System.out.println("Pairing crypto compatibility tests passed (no system XDH)");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
