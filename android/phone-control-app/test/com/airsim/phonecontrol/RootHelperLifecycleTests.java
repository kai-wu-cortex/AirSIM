package com.airsim.phonecontrol;

public final class RootHelperLifecycleTests {
    private static int checks;
    public static void main(String[] args) {
        String pkg = "com.airsim.phonecontrol.standalone";
        String cache = "/data/user/0/" + pkg + "/cache";
        String old = String.join("\0", "app_process", "/system/bin", "com.airsim.phonecontrol.RootBridgeMain", pkg,
                "21064", cache + "/root-bridge-a9403c18-1450-410a-adb2-a9a00ce8f636.token") + '\0';
        check(RootHelperIdentity.isLegacyHelper(old, pkg, cache), "observed legacy command must migrate");
        check(!RootHelperIdentity.isLegacyHelper(old + String.join("\0", "8136", "12345") + '\0', pkg, cache), "owner-aware helper must survive migration");
        check(!RootHelperIdentity.isLegacyHelper(old, "another.package", cache), "other app selected");
        check(!RootHelperIdentity.isLegacyHelper(old.replace("/data/user/0/", "/data/user/10/"), pkg, cache), "other user selected");
        check(!RootHelperIdentity.isLegacyHelper(old.replace("RootBridgeMain", "PhoneAudioBridge"), pkg, cache), "PCM child selected as supervisor");
        check(!RootHelperIdentity.isLegacyHelper(old.replace("app_process\0", "sh\0"), pkg, cache), "shell wrapper selected");
        check(!RootHelperIdentity.isLegacyHelper(old.replace("root-bridge-a940", "foreign-a940"), pkg, cache), "unrelated token path selected");
        String[] fields = new String[20];
        java.util.Arrays.fill(fields, "0"); fields[0] = "S"; fields[19] = "987654";
        String stat = "8136 (name with ) spaces) " + String.join(" ", fields);
        check(RootHelperIdentity.startTime(stat).equals("987654"), "process name shifted start-time field");
        check(!RootHelperIdentity.startTime(stat.replace("987654", "987655")).equals("987654"), "PID reuse missed");
        check(RootHelperIdentity.startTime("bad stat").isEmpty(), "bad identity accepted");
        for (String selected : new String[]{"AUTO", "ROOT"}) {
            check(PrivilegeChannelGate.canStartRoot(selected, false, false), "root selection cannot start");
            check(!PrivilegeChannelGate.canStartRoot(selected, true, false), "duplicate healthy Root launch");
            check(!PrivilegeChannelGate.canStartRoot(selected, false, true), "duplicate in-flight launch");
            check(!PrivilegeChannelGate.canBindShizuku(selected, false, true), "Shizuku races Root startup");
            check(!PrivilegeChannelGate.canBindShizuku(selected, true, false), "Shizuku steals Root ownership");
        }
        check(PrivilegeChannelGate.canBindShizuku("AUTO", false, false), "root failure must allow fallback");
        check(!PrivilegeChannelGate.canBindShizuku("ROOT", false, false), "root-only silently fell back");
        check(PrivilegeChannelGate.canBindShizuku("SHIZUKU", false, true), "new Shizuku choice blocked by obsolete Root request");
        check(!PrivilegeChannelGate.canStartRoot("SHIZUKU", false, false), "Shizuku-only launched Root");
        check(!PrivilegeChannelGate.accepts(1, 3), "ROOT -> SHIZUKU -> ROOT must reject first Root result");
        check(PrivilegeChannelGate.accepts(3, 3), "current connection rejected");
        System.out.println("Root helper lifecycle tests passed: " + checks + " assertions");
    }
    private static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
}
