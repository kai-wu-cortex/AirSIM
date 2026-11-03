package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONObject;

public final class PureLocalSMSStoreTests {
    public static void main(String[] args) throws Exception {
        var context = new Context();
        var registration = new JSONObject().put("cloud_enabled", true).put("local_mode", false)
                .put("android_agent_id", "fixture-agent").put("android_device_name", "fixture")
                .put("android_agent_kind", "standalone").put("android_phone_number", "fixture")
                .put("device_id", "fixture").put("device_secret", "fixture-secret-12345")
                .put("relay_url", "https://fixture.invalid").put("bundle_id", "test.fixture")
                .put("environment", "sandbox");
        context.getSharedPreferences("standalone_agent", 0).edit().putString("registration", registration.toString()).commit();
        var agent = new StandaloneAgentStore(context);
        assert !agent.cloudEnabled() : "old registration bypassed persisted restriction";
        assert !agent.pushStatus().getBoolean("cloud_enabled");
        try { agent.setCloudEnabled(true); throw new AssertionError("old UI unblocked cloud"); }
        catch (IllegalStateException expected) {}
        var sms = new StandaloneSMSStore(context);
        sms.add(new JSONObject().put("delivery_id", "local-1").put("content", "fixture"), true);
        assert sms.localMessages().length() == 1;
        RelayEgressGate.shared.enableAfterRestore();
        assert agent.cloudEnabled() : "raw cloud preference was destroyed";
        assert sms.cloudPending().length() == 0 : "local-period SMS was queued for later cloud upload";
        sms.add(new JSONObject().put("delivery_id", "before-2").put("content", "fixture"), true);
        assert sms.cloudPending().length() == 1;
        RelayEgressGate.shared.disableAndDrain(1000);
        sms.discardCloudBacklog();
        RelayEgressGate.shared.enableAfterRestore();
        var restarted = new StandaloneSMSStore(context.reopen());
        assert restarted.cloudPending().length() == 0;
        assert restarted.localMessages().length() == 2 : "cloud discard deleted local SMS";
        System.out.println("PureLocalSMSStoreTests passed");
    }
}
