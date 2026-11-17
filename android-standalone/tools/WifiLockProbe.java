package com.airsim.phonecontrol;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Looper;
import android.os.PowerManager;

/** Bounded ADB/shell-only diagnostic. No network configuration or credentials are changed. */
public final class WifiLockProbe {
    public static void main(String[] args) {
        WifiManager.WifiLock wifi = null;
        PowerManager.WakeLock cpu = null;
        int result = 0;
        try {
            int seconds = args.length == 1 ? Integer.parseInt(args[0]) : 300;
            if (seconds < 10 || seconds > 900) throw new IllegalArgumentException("duration must be 10..900 seconds");
            if (Looper.myLooper() == null) Looper.prepareMainLooper();
            Context context = RootBridgeMain.appContext("com.android.shell");
            WifiManager manager = context.getSystemService(WifiManager.class);
            wifi = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "AirSIM:F50WifiProbe");
            wifi.setReferenceCounted(false);
            cpu = context.getSystemService(PowerManager.class).newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK, "AirSIM:F50WifiProbe");
            cpu.setReferenceCounted(false);
            cpu.acquire(seconds * 1000L);
            wifi.acquire();
            System.out.println("wifi_lock_held=" + wifi.isHeld() + " cpu_lock_held=" + cpu.isHeld()
                    + " duration_s=" + seconds);
            System.out.flush();
            Thread.sleep(seconds * 1000L);
        } catch (Throwable failure) {
            result = 1;
            System.err.println("wifi_probe_failed=" + failure.getClass().getSimpleName() + ": " + failure.getMessage());
        } finally {
            if (wifi != null && wifi.isHeld()) wifi.release();
            if (cpu != null && cpu.isHeld()) cpu.release();
        }
        System.exit(result);
    }
}
