package com.airsim.phonecontrol;

import android.app.Application;

/** Application entry point for the AVF-free APK variant. */
public final class StandaloneBridgeApplication extends Application {
    @Override public void onCreate() {
        super.onCreate();
        BridgeLog.initialize(this);
        BridgeLog.info("standalone_application_started sdk=" + android.os.Build.VERSION.SDK_INT);
        ShizukuBridgeManager.initialize(this);
        StandaloneAgentService.start(this);
    }
}
