package com.airsim.phonecontrol;

/** One prompt per Activity launch; unavailable UI must not consume the check. */
final class ShizukuStartupPolicy {
    enum Prompt { NONE, INSTALL, START, AUTHORIZE }
    private boolean checked;

    ShizukuStartupPolicy(boolean checked) { this.checked = checked; }
    boolean checked() { return checked; }

    Prompt inspect(boolean installed, boolean running, boolean authorized, boolean canPresent) {
        if (checked || !canPresent) return Prompt.NONE;
        checked = true;
        if (running) return authorized ? Prompt.NONE : Prompt.AUTHORIZE;
        return installed ? Prompt.START : Prompt.INSTALL;
    }
}
