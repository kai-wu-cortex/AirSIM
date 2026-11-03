package com.airsim.phonecontrol;

import android.content.Context;

/** Test-only no-op: SMS compatibility compiles the real executor without the network uploader. */
final class FeedbackUploader {
    private FeedbackUploader() {}
    static void submit(Context context, String trigger, String eventID) {}
}
