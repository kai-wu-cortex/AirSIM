package com.airsim.phonecontrol;

public final class WireJson {
    private WireJson() {}

    public static String callEvent(String eventId, String callId, String direction, String state, String number, String mode) {
        return "{" +
                field("event_id", eventId) + "," +
                field("call_id", callId) + "," +
                field("direction", direction) + "," +
                field("state", state) + "," +
                field("number", number) + "," +
                field("mode", mode) + "}";
    }

    public static String commandResult(String id, boolean success, String error) {
        return "{" + field("id", id) + ",\"success\":" + success + "," + field("error", error) + "}";
    }

	public static String commandResult(String id, boolean success, String error, int segments) {
		return "{" + field("id", id) + ",\"success\":" + success + "," + field("error", error)
				+ ",\"segments\":" + Math.max(0, segments) + "}";
	}

	public static String smsEvent(String eventId, String deliveryId, String sender, String content, String timestamp) {
		return "{" + field("event_id", eventId) + "," + field("delivery_id", deliveryId) + ","
				+ field("sender", sender) + "," + field("content", content) + ","
				+ field("timestamp", timestamp) + "}";
	}

    private static String field(String key, String value) {
        return "\"" + key + "\":\"" + escape(value == null ? "" : value) + "\"";
    }

    static String escape(String value) {
        StringBuilder output = new StringBuilder(value.length() + 16);
        for (int i = 0; i < value.length(); i++) {
            char character = value.charAt(i);
            switch (character) {
                case '\\' -> output.append("\\\\");
                case '"' -> output.append("\\\"");
                case '\n' -> output.append("\\n");
                case '\r' -> output.append("\\r");
                case '\t' -> output.append("\\t");
                default -> {
                    if (character < 0x20) output.append(String.format("\\u%04x", (int) character));
                    else output.append(character);
                }
            }
        }
        return output.toString();
    }
}
