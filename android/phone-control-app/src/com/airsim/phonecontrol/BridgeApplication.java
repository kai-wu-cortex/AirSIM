package com.airsim.phonecontrol;

import android.app.Application;

public final class BridgeApplication extends Application {
    @Override public void onCreate() {
        super.onCreate();
        BridgeLog.initialize(this);
        BridgeLog.info("application_started sdk=" + android.os.Build.VERSION.SDK_INT);
        ShizukuBridgeManager.initialize(this);
    }
}
