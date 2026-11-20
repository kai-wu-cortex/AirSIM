package com.airsim.phonecontrol;
import java.util.List;
public final class VoWLANListenerPlanTests {
    public static void main(String[] args) {
        String wifi = "192.168.6.178", hotspot = "172.28.250.17";
        check(VoWLANListenerPlan.isLocalInterface("wlan0", wifi), "Wi-Fi listener available");
        check(VoWLANListenerPlan.isLocalInterface("swlan0", hotspot), "hotspot listener available simultaneously");
        check(!VoWLANListenerPlan.isLocalInterface("rmnet_data0", wifi), "do not open cellular ingress");
        check(!VoWLANListenerPlan.isLocalInterface("wlan0", "8.8.8.8"), "public address rejected");
        check(VoWLANListenerPlan.primary(wifi, hotspot, List.of(wifi, hotspot)).equals(wifi),
            "new hotspot must not tear down the working Wi-Fi primary");
        check(VoWLANListenerPlan.primary(hotspot, wifi, List.of(wifi, hotspot)).equals(hotspot),
            "returning Wi-Fi must not tear down the working hotspot primary");
        check(VoWLANListenerPlan.primary(wifi, hotspot, List.of(hotspot)).equals(hotspot),
            "switch only when the old address has actually disappeared");
        check(VoWLANListenerPlan.retainAdditional(hotspot, List.of("127.0.0.1"), hotspot),
            "promotion must retain the existing control and PCM sockets");
        check(!VoWLANListenerPlan.retainAdditional(wifi, List.of("127.0.0.1"), hotspot),
            "remove only interfaces that are gone");
        System.out.println("VoWLANListenerPlanTests passed");
    }
    private static void check(boolean ok, String why) { if (!ok) throw new AssertionError(why); }
}
