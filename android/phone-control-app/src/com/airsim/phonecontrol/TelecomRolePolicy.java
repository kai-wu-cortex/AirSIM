package com.airsim.phonecontrol;

public final class TelecomRolePolicy {
    private TelecomRolePolicy() {}

    public static boolean requiresDialerRole(String action) {
        if (action == null) return false;
        return switch (action) {
            case "dial", "answer", "reject", "end", "dtmf" -> true;
            default -> false;
        };
    }

    public static boolean canExecuteCallCommand(boolean dialerRoleHeld, String action) {
        return dialerRoleHeld && requiresDialerRole(action);
    }
}
