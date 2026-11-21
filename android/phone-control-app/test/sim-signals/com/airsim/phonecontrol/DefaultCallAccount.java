package com.airsim.phonecontrol;
import android.content.Context;
public final class DefaultCallAccount {
    public record Account(String key, String label, int slotIndex, int subscriptionId) {
        public String number() { return ""; } public String carrierName() { return "Carrier"; }
        public boolean embedded() { return false; } public boolean defaultVoice() { return false; }
        public boolean defaultSms() { return false; }
    }
    public record Snapshot(java.util.List<Account> accounts, String error) {}
    public static java.util.List<Account> accounts = java.util.List.of(new Account("A", "SIM 1", 0, 10), new Account("B", "SIM 2", 1, 20));
    public static Snapshot snapshot(Context context) { return new Snapshot(accounts, ""); }
    public static String selectedKey(Context context) { return "A"; }
}
