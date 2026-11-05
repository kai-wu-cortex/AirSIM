package com.airsim.bridge;

import java.util.Arrays;

public final class Redmi9PCMTests {
    private static int checks;
    public static void main(String[] args) {
        check(Redmi9PCMProfile.matches("Xiaomi", "lancelot", "mt6768"), "target not matched");
        check(!Redmi9PCMProfile.matches("Samsung", "lancelot", "mt6768"), "Samsung policy changed");
        check(!Redmi9PCMProfile.matches("Xiaomi", "begonia", "mt6785"), "untested MTK model opted in");
        check(!Redmi9PCMProfile.matches(null, null, null), "unknown device opted in");
        check(Redmi9PCMProfile.playbackRate(new int[]{44100,48000}, new int[]{2}, new int[]{2,4}) == 48000, "Redmi Tx profile");
        check(Redmi9PCMProfile.playbackRate(new int[]{8000}, new int[]{1}, new int[]{2}) == 8000, "native wire format fallback");
        rejects(() -> Redmi9PCMProfile.playbackRate(new int[]{44100}, new int[]{2}, new int[]{2}), "unsupported fractional conversion silently enabled");
        rejects(() -> Redmi9PCMProfile.playbackRate(new int[]{48000}, new int[]{2}, new int[]{4}), "PCM encoding mismatch accepted");
        byte[] wire = new byte[640];
        for (int i = 0; i < wire.length / 2; i++) {
            short sample = (short) Math.round(Math.sin(i * 2 * Math.PI * 1000 / 8000) * 20000);
            wire[2*i] = (byte) sample; wire[2*i+1] = (byte) (sample >> 8);
        }
        byte[] whole = new byte[wire.length * 12];
        check(new PCM8kTo48kStereo().convert(wire, wire.length, whole) == 7680, "40 ms output duration changed");
        PCM8kTo48kStereo streaming = new PCM8kTo48kStereo();
        java.io.ByteArrayOutputStream parts = new java.io.ByteArrayOutputStream();
        for (int offset = 0; offset < wire.length; ) {
            int count = Math.min(wire.length - offset, offset % 3 == 0 ? 2 : 74);
            byte[] frame = Arrays.copyOfRange(wire, offset, offset + count);
            byte[] converted = new byte[count * 12];
            parts.write(converted, 0, streaming.convert(frame, count, converted));
            offset += count;
        }
        check(Arrays.equals(whole, parts.toByteArray()), "frame boundaries changed samples or duration");
        for (int i = 0; i < whole.length; i += 4) {
            if (whole[i] != whole[i+2] || whole[i+1] != whole[i+3]) throw new AssertionError("stereo channels differ");
        }
        checks++;
        byte[] extrema = new byte[]{0, -128, -1, 127};
        byte[] extremeOut = new byte[48];
        new PCM8kTo48kStereo().convert(extrema, 4, extremeOut);
        check(sample(extremeOut, 0) == -32768 && sample(extremeOut, 44) == 32767, "signed PCM/clipping error");
        byte[] silent = new byte[3840];
        new PCM8kTo48kStereo().convert(new byte[320], 320, silent);
        check(Arrays.equals(silent, new byte[3840]), "silent input produced noise");
        rejects(() -> new PCM8kTo48kStereo().convert(new byte[3], 3, new byte[36]), "odd frame accepted");
        rejects(() -> new PCM8kTo48kStereo().convert(new byte[320], 320, new byte[320]), "short output accepted");
        System.out.println("Redmi9PCMTests passed: " + checks + " assertions (synthetic PCM only)");
    }
    private static int sample(byte[] value, int offset) { return (short) ((value[offset] & 255) | (value[offset+1] << 8)); }
    private static void rejects(Runnable action, String text) {
        try { action.run(); throw new AssertionError(text); }
        catch (IllegalArgumentException | IllegalStateException expected) { checks++; }
    }
    private static void check(boolean value, String text) { checks++; if (!value) throw new AssertionError(text); }
}
