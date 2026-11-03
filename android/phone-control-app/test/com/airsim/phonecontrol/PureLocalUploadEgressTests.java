package com.airsim.phonecontrol;

import java.net.*;
import java.lang.reflect.*;
import org.json.JSONObject;

public final class PureLocalUploadEgressTests {
    public static void main(String[] args) throws Exception {
        URL.setURLStreamHandlerFactory(protocol -> "https".equals(protocol) ? new URLStreamHandler() {
            protected URLConnection openConnection(URL url) {
                return new StandaloneRelayEgressTests.CountingConnection(url);
            }
        } : null);
        Method feedback = FeedbackUploader.class.getDeclaredMethod("post", String.class, RelayEgressGate.Generation.class);
        Method forwarding = NotificationForwarder.class.getDeclaredMethod("post", String.class,
                String.class, JSONObject.class, String.class, RelayEgressGate.Generation.class);
        feedback.setAccessible(true); forwarding.setAccessible(true);
        Method[] methods = {feedback, forwarding};
        Object[][] inputs = {{"{}", null}, {"https://fixture.invalid", "{}", new JSONObject(), "webhook", null}};
        for (int index = 0; index < methods.length; index++) {
            RelayEgressGate.shared.disableAndDrain(1000);
            int before = StandaloneRelayEgressTests.sends.get();
            inputs[index][inputs[index].length - 1] = RelayEgressGate.shared.generation();
            try { methods[index].invoke(null, inputs[index]); }
            catch (InvocationTargetException error) {
                if (!(error.getCause() instanceof java.io.IOException)) throw error;
            }
            assert before == StandaloneRelayEgressTests.sends.get() : methods[index] + " bypassed pure-local";
            RelayEgressGate.shared.enableAfterRestore();
            inputs[index][inputs[index].length - 1] = RelayEgressGate.shared.generation();
            methods[index].invoke(null, inputs[index]);
            assert before + 1 == StandaloneRelayEgressTests.sends.get();
            assert RelayEgressGate.shared.disableAndDrain(1000);
        }
        System.out.println("PureLocalUploadEgressTests passed");
    }
}
