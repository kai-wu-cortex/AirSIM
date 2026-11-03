package com.airsim.phonecontrol;

public final class FeedbackUploadPolicyTests {
    public static void main(String[] args) {
        for (String trigger : new String[]{null, "", "periodic", "error", "call_ended",
                "sms_sent", "sms_received", "crash", "startup", "MANUAL", " manual "}) {
            if (FeedbackUploadPolicy.allows(trigger)) throw new AssertionError("unexpected upload: " + trigger);
        }
        if (!FeedbackUploadPolicy.allows("manual")) throw new AssertionError("manual upload disabled");
        System.out.println("FeedbackUploadPolicyTests passed");
    }
}
