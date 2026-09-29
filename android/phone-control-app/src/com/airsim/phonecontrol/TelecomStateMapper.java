package com.airsim.phonecontrol;

public final class TelecomStateMapper {
    private TelecomStateMapper() {}

    public static String toWireState(int state) {
        return switch (state) {
            case 1, 8, 9 -> "dialing";
            case 2, 13 -> "incoming";
            case 3 -> "held";
            case 4 -> "active";
            case 7, 10 -> "ended";
            default -> "unknown";
        };
    }

	public static boolean shouldSilenceLocalOutput(String mode, String wireState) {
		if (!"remote_silent".equals(mode)) return false;
		return "dialing".equals(wireState)
				|| "incoming".equals(wireState)
				|| "active".equals(wireState)
				|| "held".equals(wireState);
	}
}
