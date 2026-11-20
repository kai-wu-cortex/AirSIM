package com.airsim.phonecontrol;

final class BridgeNotification {
    static boolean wakesForCalls(android.content.Context context, String mode) { return true; }
    static void clearCall(android.content.Context context, String id) {}
    static void showCall(android.content.Context context, String id, String direction, String mode, String state, String number) {}
}
