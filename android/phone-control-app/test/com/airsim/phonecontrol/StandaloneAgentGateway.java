package com.airsim.phonecontrol;

import android.content.Context;

final class StandaloneAgentGateway {
    static StandaloneAgentGateway get(Context context) { return new StandaloneAgentGateway(); }
    String status() { return "{}"; }
    String health() { return "{}"; }
    String pushStatus() { return "{}"; }
    String debugSnapshot() { return "{}"; }
    String registerPairing(String value) { return "{}"; }
    void sendCallEvent(String value) {}
    void sendSMSEvent(String value) {}
    AgentClient.ForwardResponse forward(String method, String path, String body) {
        return new AgentClient.ForwardResponse(200, "{}");
    }
}
