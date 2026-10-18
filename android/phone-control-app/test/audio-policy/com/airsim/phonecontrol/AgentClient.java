package com.airsim.phonecontrol;

/** No external event transport during JVM audio lifecycle tests. */
final class AgentClient {
    AgentClient(android.content.Context context) {}
    void sendEvent(String value) {}
}
