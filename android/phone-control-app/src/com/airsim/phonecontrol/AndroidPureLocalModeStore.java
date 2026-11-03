package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;
import java.io.IOException;

/** Single app-private policy file, independent of registrations received from other peers. */
final class AndroidPureLocalModeStore {
    static PureLocalModeStore open(Context context) {
        SharedPreferences preferences = context.getApplicationContext()
                .getSharedPreferences("pure_local_mode_v1", Context.MODE_PRIVATE);
        return new PureLocalModeStore(AndroidAgentIdentity.agentID(context), new PureLocalModeStore.Backend() {
            public String read() { return preferences.getString("transaction", null); }
            public void write(String value) throws IOException {
                if (!preferences.edit().putString("transaction", value).commit()) {
                    throw new IOException("pure_local_persistence_failed");
                }
            }
        });
    }
    static void initializeEgress(Context context) {
        // Application startup only; never called by a registration, service restart or retry.
        if (!open(context).read().blocked) RelayEgressGate.shared.enableAfterRestore();
    }
    private AndroidPureLocalModeStore() {}
}
