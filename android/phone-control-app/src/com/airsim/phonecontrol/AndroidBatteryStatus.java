package com.airsim.phonecontrol;

import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import org.json.JSONObject;

/** Read the OS sticky battery broadcast; no receiver, permission or polling loop. */
public final class AndroidBatteryStatus {
    private AndroidBatteryStatus() {}

    public static int percent(int level, int scale) {
        if (level < 0 || scale <= 0 || level > scale) return -1;
        return (int) Math.round(100.0 * level / scale);
    }

    public static JSONObject snapshot(Context context) {
        try {
            Intent value = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (value == null) return null;
            int percent = percent(value.getIntExtra(BatteryManager.EXTRA_LEVEL, -1),
                    value.getIntExtra(BatteryManager.EXTRA_SCALE, -1));
            if (percent < 0) return null;
            int status = value.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
            boolean charging = status == BatteryManager.BATTERY_STATUS_CHARGING
                    || status == BatteryManager.BATTERY_STATUS_FULL;
            return new JSONObject().put("percent", percent).put("charging", charging)
                    .put("observed_at_ms", System.currentTimeMillis());
        } catch (Exception ignored) {
            return null;
        }
    }
}
