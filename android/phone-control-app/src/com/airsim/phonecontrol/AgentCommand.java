package com.airsim.phonecontrol;

public final class AgentCommand {
    public final String id;
    public final String action;
    public final String callId;
    public final String number;
	public final String message;
    public final int slotId;
    public final int subId;
    public final String slot;

    AgentCommand(String id, String action, String callId, String number) {
		this(id, action, callId, number, "");
	}

	AgentCommand(String id, String action, String callId, String number, String message) {
        this(id, action, callId, number, message, -1, -1, "");
    }

    AgentCommand(String id, String action, String callId, String number, String message,
                 int slotId, int subId, String slot) {
        this.id = id;
        this.action = action;
        this.callId = callId;
        this.number = number;
        this.message = message;
        this.slotId = slotId;
        this.subId = subId;
        this.slot = slot == null ? "" : slot;
    }

    public static AgentCommand parse(String json) {
        String slotStr = value(json, "slot");
        int slotId = intValue(json, "slot_id");
        if (slotId < 0 && slotStr.length() > 0) {
            slotId = SIMSlotManager.parseSlotIdentifier(slotStr);
        }
        int subId = intValue(json, "sub_id");
        return new AgentCommand(value(json, "id"), value(json, "action"), value(json, "call_id"),
				value(json, "number"), value(json, "message"), slotId, subId, slotStr);
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

    private static int intValue(String json, String key) {
        String marker = "\"" + key + "\"";
        int start = json == null ? -1 : json.indexOf(marker);
        if (start < 0) return -1;
        start = json.indexOf(':', start + marker.length());
        if (start < 0) return -1;
        start++;
        while (start < json.length() && Character.isWhitespace(json.charAt(start))) start++;
        if (start >= json.length()) return -1;
        if (json.charAt(start) == '"') {
            start++;
            int end = json.indexOf('"', start);
            if (end < 0) return -1;
            try { return Integer.parseInt(json.substring(start, end)); } catch (Exception ignored) { return -1; }
        }
        int end = start;
        while (end < json.length() && (Character.isDigit(json.charAt(end)) || json.charAt(end) == '-')) end++;
        if (end == start) return -1;
        try { return Integer.parseInt(json.substring(start, end)); } catch (Exception ignored) { return -1; }
    }
}
