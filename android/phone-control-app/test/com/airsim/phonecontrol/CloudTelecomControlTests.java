package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Real gateway/Telecom calls with synthetic Android services; no carrier or socket traffic. */
public final class CloudTelecomControlTests {
    public static void main(String[] args) throws Exception {
        RelayEgressGate.shared.enableAfterRestore();
        int failures = 0;
        try { simCallbackCanFinishWhileTelecomCommandWaits(); }
        catch (AssertionError failure) { failures++; System.err.println(failure.getMessage()); }
        try { outgoingMediaAnswerDoesNotAnswerCarrierCall(); }
        catch (AssertionError failure) { failures++; System.err.println(failure.getMessage()); }
        try { incomingAnswerStillRequiresTelecom(); }
        catch (AssertionError failure) { failures++; System.err.println(failure.getMessage()); }
        if (failures != 0) throw new AssertionError(failures + " cloud Telecom regression(s)");
        System.out.println("CloudTelecomControlTests passed");
    }

    private static StandaloneAgentGateway gateway() throws Exception {
        return gateway(true);
    }

    private static StandaloneAgentGateway gateway(boolean dialer) throws Exception {
        var context = new android.content.Context();
        if (dialer) context.setSystemService(android.app.role.RoleManager.class, new android.app.role.RoleManager());
        var constructor = StandaloneAgentGateway.class.getDeclaredConstructor(android.content.Context.class);
        constructor.setAccessible(true);
        return constructor.newInstance(context);
    }

    private static JSONObject command(String type, String action) {
        return new JSONObject().put("command_id", java.util.UUID.randomUUID().toString())
                .put("type", type).put("action", action).put("number", "1")
                .put("call", new JSONObject().put("call_id", "new-cloud-call")
                        .put("call_uuid", "11111111-1111-4111-8111-111111111111").put("generation", 1));
    }

    private static void simCallbackCanFinishWhileTelecomCommandWaits() throws Exception {
        var entered = new CountDownLatch(1);
        var callbackFinished = new CountDownLatch(1);
        var call = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE, 1, "5550100") {
            @Override public void playDtmfTone(char digit) {
                entered.countDown();
                try {
                    if (!callbackFinished.await(1, TimeUnit.SECONDS))
                        throw new IllegalStateException("SIM callback blocked behind Telecom command");
                } catch (InterruptedException interrupted) { throw new RuntimeException(interrupted); }
            }
        };
        String id = CallRepository.add(call);
        var threads = Executors.newFixedThreadPool(2);
        var singleton = StandaloneCloudMediaManager.class.getDeclaredField("instance");
        singleton.setAccessible(true);
        Object previous = singleton.get(null);
        try (var fixture = new CloudCallManagerTests.Fixture(id)) {
            singleton.set(null, fixture.manager);
            var gateway = gateway();
            var result = threads.submit(() -> gateway.executeCloudCommand(command("dtmf", "")));
            check(entered.await(2, TimeUnit.SECONDS), "Telecom action never started");
            var callback = threads.submit(() -> {
                gateway.simSlotsChanged();
                callbackFinished.countDown();
            });
            var response = result.get(3, TimeUnit.SECONDS);
            callback.get(2, TimeUnit.SECONDS);
            check("completed".equals(response.optString("status")),
                    "SIM callback/Telecom lock inversion: " + response.optString("error"));
        } finally {
            callbackFinished.countDown();
            singleton.set(null, previous);
            CallRepository.remove(call);
            threads.shutdownNow(); threads.awaitTermination(3, TimeUnit.SECONDS);
        }
    }

    private static void outgoingMediaAnswerDoesNotAnswerCarrierCall() throws Exception {
        var nativeAnswers = new AtomicInteger();
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100") {
            @Override public void answer(int state) { nativeAnswers.incrementAndGet(); super.answer(state); }
        };
        String id = CallRepository.add(call);
        var singleton = StandaloneCloudMediaManager.class.getDeclaredField("instance");
        singleton.setAccessible(true);
        Object previous = singleton.get(null);
        try (var fixture = new CloudCallManagerTests.Fixture(id)) {
            singleton.set(null, fixture.manager);
            var gateway = gateway();
            var answer = command("call_control", "answer");
            var result = gateway.executeCloudCommand(answer);
            check("completed".equals(result.optString("status")),
                    "Outgoing media acknowledgement rejected: " + result.optString("error"));
            check(call.getState() == android.telecom.Call.STATE_DIALING && nativeAnswers.get() == 0,
                    "Media acknowledgement must not manufacture carrier ACTIVE or call answer()");
            check("completed".equals(gateway.executeCloudCommand(answer).optString("status")),
                    "Exact command replay must remain idempotent");
            check("failed".equals(gateway(false).executeCloudCommand(command("call_control", "answer")).optString("status")),
                    "Outgoing media acknowledgement must still require the dialer role");
            call.setStateForTest(android.telecom.Call.STATE_CONNECTING);
            check("completed".equals(gateway.executeCloudCommand(command("call_control", "answer")).optString("status"))
                            && call.getState() == android.telecom.Call.STATE_CONNECTING && nativeAnswers.get() == 0,
                    "Early CONNECTING acknowledgement must preserve carrier state");
            var stale = command("call_control", "answer");
            stale.getJSONObject("call").put("generation", 2);
            check("failed".equals(gateway.executeCloudCommand(stale).optString("status")),
                    "Wrong call generation must not acknowledge media");
            CallRepository.remove(call);
            check("failed".equals(gateway.executeCloudCommand(command("call_control", "answer")).optString("status")),
                    "Ended call must not acknowledge new media commands");
        } finally { singleton.set(null, previous); CallRepository.remove(call); }
    }

    private static void incomingAnswerStillRequiresTelecom() throws Exception {
        var nativeAnswers = new AtomicInteger();
        var call = new android.telecom.Call(android.telecom.Call.STATE_RINGING, 0, "5550100") {
            @Override public void answer(int state) { nativeAnswers.incrementAndGet(); super.answer(state); }
        };
        String id = CallRepository.add(call);
        var singleton = StandaloneCloudMediaManager.class.getDeclaredField("instance");
        singleton.setAccessible(true);
        Object previous = singleton.get(null);
        try (var fixture = new CloudCallManagerTests.Fixture(id)) {
            singleton.set(null, fixture.manager);
            var result = gateway().executeCloudCommand(command("call_control", "answer"));
            check("completed".equals(result.optString("status")) && nativeAnswers.get() == 1
                            && call.getState() == android.telecom.Call.STATE_ACTIVE,
                    "Incoming answer must still invoke Telecom and confirm ACTIVE");
        } finally { singleton.set(null, previous); CallRepository.remove(call); }
    }

    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
