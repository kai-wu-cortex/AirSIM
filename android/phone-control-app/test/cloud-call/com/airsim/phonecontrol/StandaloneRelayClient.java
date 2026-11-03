package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

/** External HTTP boundary only; the call-event manager under test is production code. */
final class StandaloneRelayClient {
    final List<JSONObject> states = new ArrayList<>();
    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeout) throws Exception {
        if (path.equals("/v2/events/call-state")) states.add(new JSONObject(payload.toString()));
        return new JSONObject();
    }
}
