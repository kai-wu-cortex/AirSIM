package com.airsim.phonecontrol;

import java.util.Locale;
import java.util.Set;

public final class AVFStartupPolicy {
    public enum State {
        RUNNING,
        READY_TO_START,
        TERMINAL_DISABLED,
        TERMINAL_MISSING,
        AVF_UNSUPPORTED
    }

    private static final Set<String> RESTRICTED_CHINA_OEMS = Set.of(
            "xiaomi", "redmi", "oppo", "oneplus", "realme", "vivo", "iqoo", "honor");
    private static final String INSTALL_COMMAND =
            "curl -fsSL --proto '=https' --tlsv1.2 " +
            "https://github.com/kai-wu-cortex/AirSIM/releases/latest/download/install-avf.sh | sudo sh";

    private AVFStartupPolicy() {}

    public static State assess(
            boolean hasAVFSystemFeature,
            boolean terminalInstalled,
            boolean terminalEnabled,
            boolean avfNetworkActive) {
        if (avfNetworkActive) return State.RUNNING;
        if (!hasAVFSystemFeature) return State.AVF_UNSUPPORTED;
        if (!terminalInstalled) return State.TERMINAL_MISSING;
        if (!terminalEnabled) return State.TERMINAL_DISABLED;
        return State.READY_TO_START;
    }

    public static boolean isRestrictedChinaOEM(String manufacturer) {
        if (manufacturer == null) return false;
        return RESTRICTED_CHINA_OEMS.contains(manufacturer.trim().toLowerCase(Locale.ROOT));
    }

    public static boolean shouldPrompt(State state, boolean agentConfigured) {
        return state != State.RUNNING || !agentConfigured;
    }

    public static String installCommand() {
        return INSTALL_COMMAND;
    }
}
