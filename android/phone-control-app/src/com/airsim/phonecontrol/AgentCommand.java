package com.airsim.phonecontrol;

public final class AgentCommand {
    public final String id;
    public final String action;
    public final String callId;
    public final String number;
	public final String message;

    AgentCommand(String id, String action, String callId, String number) {
		this(id, action, callId, number, "");
	}

	AgentCommand(String id, String action, String callId, String number, String message) {
        this.id = id;
        this.action = action;
        this.callId = callId;
        this.number = number;
		this.message = message;
    }

    public static AgentCommand parse(String json) {
        return new AgentCommand(value(json, "id"), value(json, "action"), value(json, "call_id"),
				value(json, "number"), value(json, "message"));
    }

    public boolean isSupported() {
        return !id.isEmpty() && switch (action) {
            case "answer", "reject", "end", "dial", "dtmf", "send_sms" -> true;
            default -> false;
        };
    }

    private static String value(String json, String key) {
        String marker = "\"" + key + "\"";
        int start = json == null ? -1 : json.indexOf(marker);
        if (start < 0) return "";
        start = json.indexOf(':', start + marker.length());
        if (start < 0) return "";
        start++;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) start++;
        if (start >= json.length() || json.charAt(start) != '"') return "";
        start++;
        StringBuilder output = new StringBuilder();
        boolean escaped = false;
        for (int i = start; i < json.length(); i++) {
            char character = json.charAt(i);
            if (escaped) {
                output.append(switch (character) {
                    case 'n' -> '\n'; case 'r' -> '\r'; case 't' -> '\t';
                    default -> character;
                });
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == '"') {
                return output.toString();
            } else {
                output.append(character);
            }
        }
        return "";
    }
}
