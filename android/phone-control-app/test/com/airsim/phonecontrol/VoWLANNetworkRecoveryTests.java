package com.airsim.phonecontrol;

public final class VoWLANNetworkRecoveryTests {
    public static void main(String[] args) {
        VoWLANNetworkRecoveryGate gate = new VoWLANNetworkRecoveryGate();
        gate.observe("network-1:wlan0:192.168.1.2", 0);
        check(!gate.consume(0), "wait for route/address settling");
        check(gate.nextDelay(0, 5000) == 1000, "pending network must be revisited without waiting full polling delay");
        check(gate.consume(1000), "first Wi-Fi network requires publication");
        gate.observe("network-1:wlan0:192.168.1.2", 2000);
        check(!gate.consume(4000), "duplicate callbacks must not re-register constantly");
        gate.observe("", 5000);
        gate.observe("network-2:wlan0:192.168.1.2", 5500);
        check(!gate.consume(6000) && gate.consume(6500), "same IP on a new network must republish after settling");
        check(!gate.consume(7000), "each stable revision is consumed once");
        gate.observe("network-3:wlan0:192.168.1.2", 8000);
        gate.close();
        gate.observe("late-callback", 9000);
        check(!gate.consume(10000), "late callback cannot revive a destroyed service");

        VoWLANAdvertisementEpoch advertisement = new VoWLANAdvertisementEpoch();
        long oldRegistration = advertisement.begin();
        advertisement.invalidate();
        advertisement.completed(oldRegistration, true);
        check(!advertisement.isReady(), "retired NSD success cannot suppress network recovery");
        long currentRegistration = advertisement.begin();
        advertisement.completed(currentRegistration, true);
        advertisement.completed(oldRegistration, false);
        check(advertisement.isReady(), "old NSD failure cannot clear current success");
        advertisement.invalidate();
        advertisement.completed(currentRegistration, true);
        check(!advertisement.isReady(), "late success cannot revive a stopped advertisement");
        System.out.println("VoWLANNetworkRecoveryTests passed");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
