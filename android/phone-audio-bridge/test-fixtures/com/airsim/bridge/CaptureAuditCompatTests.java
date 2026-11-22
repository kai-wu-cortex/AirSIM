package com.airsim.bridge;

import android.media.AudioRecord;
import android.os.Build;
import java.lang.reflect.Field;

public final class CaptureAuditCompatTests {
    private static int checks;
    private static void check(boolean value, String message) {
        checks++;
        if (!value) throw new AssertionError(message);
    }
    private static AudioRecord recorder() {
        AudioRecord.starts = 0;
        AudioRecord.auditFailure = AudioRecord.unrelatedFailure = AudioRecord.retryFailure = false;
        Build.MANUFACTURER = "HONOR";
        Build.VERSION.SDK_INT = 36;
        return new AudioRecord(3, 8000, 1, 2, 320);
    }
    public static void main(String[] args) throws Exception {
        AudioRecord r = recorder();
        PhoneAudioBridge.startRecordingCompat(r, 0);
        check(AudioRecord.starts == 1 && AudioRecord.sourceAtStart == 3, "ordinary start must not mutate source");
        r.release();

        r = recorder(); AudioRecord.auditFailure = true;
        PhoneAudioBridge.startRecordingCompat(r, 0);
        check(AudioRecord.starts == 2 && AudioRecord.sourceAtStart == 5, "known audit should retry exactly once");
        check(r.getAudioSource() == 3 && AudioRecord.requestedSource == 3, "native source and Java source retained");
        check(r.getRecordingState() == 3, "capture starts");
        r.release();

        for (String manufacturer : new String[]{"samsung", "Xiaomi", "HUAWEI"}) {
            r = recorder(); Build.MANUFACTURER = manufacturer; AudioRecord.auditFailure = true;
            try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
            catch (NullPointerException expected) {}
            check(AudioRecord.starts == 1 && r.getAudioSource() == 3, "other OEM unaffected");
            r.release();
        }
        r = recorder(); Build.VERSION.SDK_INT = 35; AudioRecord.auditFailure = true;
        try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
        catch (NullPointerException expected) {}
        check(AudioRecord.starts == 1, "unverified SDK unaffected"); r.release();

        r = recorder(); AudioRecord.unrelatedFailure = true;
        try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
        catch (NullPointerException expected) {}
        check(AudioRecord.starts == 1, "unrelated NPE not retried"); r.release();

        r = recorder(); AudioRecord.auditFailure = AudioRecord.retryFailure = true;
        try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
        catch (SecurityException expected) {}
        check(AudioRecord.starts == 2 && r.getAudioSource() == 3, "retry failure restores source without another retry"); r.release();

        r = recorder(); AudioRecord.retryFailure = true;
        try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
        catch (SecurityException expected) {}
        check(AudioRecord.starts == 1, "permission denial never bypassed"); r.release();

        Field cached = PhoneAudioBridge.class.getDeclaredField("recordSourceField");
        cached.setAccessible(true); Object saved = cached.get(null); cached.set(null, null);
        r = recorder(); AudioRecord.auditFailure = true;
        try { PhoneAudioBridge.startRecordingCompat(r, 0); throw new AssertionError("must fail"); }
        catch (NullPointerException expected) {
            check(expected.getMessage().equals("private OEM message"), "original failure retained");
        } finally { cached.set(null, saved); }
        check(AudioRecord.starts == 1 && r.getAudioSource() == 3, "unavailable reflection never retries"); r.release();

        Throwable error = new NullPointerException("secret-token");
        StackTraceElement[] frames = new StackTraceElement[12];
        java.util.Arrays.fill(frames, new StackTraceElement("android.media.AudioRecord", "startRecording", "/private/path", 1560));
        error.setStackTrace(frames);
        String evidence = new AudioStartupFailure("start_capture", error).diagnosticFields().get("error_stack").toString();
        check(evidence.split(" <- ").length == 8, "stack bounded to eight frames");
        check(!evidence.contains("secret-token") && !evidence.contains("/private/path"), "message and filename not exported");
        check(AudioRecord.live == 0, "test endpoints released");
        System.out.println("PASS CaptureAuditCompatTests checks=" + checks);
    }
}
