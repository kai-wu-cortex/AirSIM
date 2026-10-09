package com.airsim.phonecontrol;

/** Chooses the next user-visible or privileged step for acquiring the dialer role. */
final class DialerRoleSetupPolicy {
    enum Action { COMPLETE, SHIZUKU, SYSTEM_ROLE, SETTINGS }

    private DialerRoleSetupPolicy() {}

    static Action initial(boolean roleHeld, boolean shizukuAuthorized) {
        if (roleHeld) return Action.COMPLETE;
        return shizukuAuthorized ? Action.SHIZUKU : Action.SYSTEM_ROLE;
    }

    static Action afterSystemRequest(boolean roleHeld, boolean shizukuAvailable) {
        if (roleHeld) return Action.COMPLETE;
        return shizukuAvailable ? Action.SHIZUKU : Action.SETTINGS;
    }

    static Action afterPrivilegedAttempt(boolean roleHeld) {
        return roleHeld ? Action.COMPLETE : Action.SETTINGS;
    }
}
