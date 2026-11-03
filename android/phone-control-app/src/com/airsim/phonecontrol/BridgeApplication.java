package com.airsim.phonecontrol;

import android.app.Application;

public final class BridgeApplication extends Application {
    @Override public void onCreate() {
        super.onCreate();
        BridgeLog.initialize(this);
        AndroidPureLocalModeStore.initializeEgress(this);
        CrashReporter.install(this);
        BridgeLog.info("application_started sdk=" + android.os.Build.VERSION.SDK_INT);
        NetworkSettings.apply(this);
        ShizukuBridgeManager.initialize(this);
        RootSmsSender.install(this);
        com.airsim.phonecontrol.voble.VoBLEGatewayService.start(this);
    }
}
