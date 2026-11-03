package com.airsim.phonecontrol;

import android.app.Application;

/** Application entry point for the AVF-free APK variant. */
public final class StandaloneBridgeApplication extends Application {
    @Override public void onCreate() {
        super.onCreate();
        BridgeLog.initialize(this);
        // Restore the persisted policy before any service can attempt Relay I/O.
        AndroidPureLocalModeStore.initializeEgress(this);
        CrashReporter.install(this);
        BridgeLog.info("standalone_application_started sdk=" + android.os.Build.VERSION.SDK_INT);
        NetworkSettings.apply(this);
        ShizukuBridgeManager.initialize(this);
        RootSmsSender.install(this);
        StandaloneAgentService.start(this);
        com.airsim.phonecontrol.voble.VoBLEGatewayService.start(this);
    }
}
