package com.airsim.phonecontrol;

import java.util.List;

/** Keep a working primary stable while binding the other local interfaces too. */
final class VoWLANListenerPlan {
    static boolean isLocalInterface(String name, String host) {
        return name != null && (name.startsWith("wlan") || name.startsWith("swlan") || name.startsWith("ap"))
                && VoWLANNetworkPolicy.isVoWLANInterface(name, host);
    }
    static String primary(String current, String preferred, List<String> available) {
        return current != null && available.contains(current) ? current : preferred;
    }
    static boolean retainAdditional(String host, List<String> wanted, String nextPrimary) {
        return wanted.contains(host) || host.equals(nextPrimary);
    }
}
