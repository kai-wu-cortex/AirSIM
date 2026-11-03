package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.lang.reflect.*;

/** Runs the actual manager without starting a socket, dial, or background executor. */
public final class CloudCallManagerTests {
    public static void main(String[] args) throws Exception {
        RelayEgressGate.shared.enableAfterRestore();
        endedBeforeEventDrainStillReleasesOutgoing();
        callCanCompleteBeforeSessionCreation();
        lateOutgoingCannotBindUnownedSession("ended");
        lateOutgoingCannotBindUnownedSession("active");
        otherCallCannotEndOwnedSession();
        ownEndedClosesSession();
        droppedEndedClosesOnlyOwner();
        pendingDialBindsOnlyUniqueNewMatchingCall();
        cachedDialCannotRecreateEndedSession();
        oldMediaCannotRestartAfterPureLocalExit();
        media401RetriesThenStopsWithoutReplacingLiveSlot();
        successfulHandshakeResetsMedia401Window();
        System.out.println("CloudCallManagerTests passed");
    }

    private static void oldMediaCannotRestartAfterPureLocalExit() throws Exception {
        try (var f = new Fixture("")) {
            Object session = f.active();
            RelayEgressGate.shared.disableAndDrain(1000);
            RelayEgressGate.shared.enableAfterRestore();
            StandaloneWebSocket.attempts = 0;
            StandaloneWebSocket.next = () -> {
                android.os.SystemClock.now = StandaloneWebSocket.attempts == 1 ? 0 : 60_000;
                throw new RelayHTTPException(401, "fixture expired");
            };
            ((Runnable) session).run();
            check(StandaloneWebSocket.attempts == 0, "old media task revived after pure-local exit");
        }
    }

    private static void callCanCompleteBeforeSessionCreation() throws Exception {
        var observation = CallRepository.observeOutgoing("5550100");
        var call = new android.telecom.Call(1, 1, "5550100");
        String id = CallRepository.add(call);
        CallRepository.remove(call);
        try (var f = new Fixture("")) {
            set(f.manager, "sessions", new QueuedExecutor());
            var descriptor = new JSONObject().put("call_id", "early-call")
                    .put("call_uuid", "22222222-2222-4222-8222-222222222222")
                    .put("call_secret", "synthetic-secret").put("relay_url", "https://example.invalid");
            f.manager.startOutgoing(descriptor, observation);
            f.manager.handleCallEvent(registration(), event("previous-call", "outgoing", "ended"), f.relay);
            check(f.active() != null && f.relay.states.isEmpty(), "old event cannot end early-completed owner");
            f.manager.handleCallEvent(registration(), event(id, "outgoing", "ended"), f.relay);
            check(f.active() == null && f.relay.states.size() == 1, "call completed before session creation must still release");
            check("early-call".equals(f.relay.states.get(0).optString("call_id")), "notify correct early-call identity");
        } finally { observation.close(); }
    }

    private static void endedBeforeEventDrainStillReleasesOutgoing() throws Exception {
        try (var f = new Fixture("")) {
            set(f.descriptor, "outgoingObservation", CallRepository.observeOutgoing("5550100"));
            var call = new android.telecom.Call(1, 1, "5550100");
            String id = CallRepository.add(call);
            call.setStateForTest(android.telecom.Call.STATE_DISCONNECTED);
            CallRepository.remove(call);
            f.manager.handleCallEvent(registration(), event(id, "outgoing", "dialing"), f.relay);
            f.manager.handleCallEvent(registration(), event(id, "outgoing", "ended"), f.relay);
            check(f.relay.states.size() == 2 && f.active() == null,
                    "outgoing that ended before queue drain must still notify and release its own cloud session");
        }
    }

    private static void media401RetriesThenStopsWithoutReplacingLiveSlot() throws Exception {
        var call = new android.telecom.Call(4);
        String id = CallRepository.add(call);
        try (var f = new Fixture(id)) {
            Object session = f.active();
            StandaloneWebSocket.attempts = 0;
            StandaloneWebSocket.next = () -> {
                android.os.SystemClock.now = StandaloneWebSocket.attempts == 1 ? 0 : 60_000;
                throw new RelayHTTPException(401, "call authentication failed");
            };
            ((Runnable) session).run();
            check(StandaloneWebSocket.attempts == 2, "401 must retry, then stop at budget");
            check(f.active() == session && !(boolean)field(session, "running"), "exhaustion must retain live slot but stop media");
            f.manager.abandonCallEvent(event(id, "incoming", "ended").toString());
            check(f.active() == null, "ended must release stopped session");
        } finally { CallRepository.remove(call); StandaloneWebSocket.next = null; }
    }

    private static void successfulHandshakeResetsMedia401Window() throws Exception {
        try (var f = new Fixture("owner")) {
            Object session = f.active();
            StandaloneWebSocket.attempts = 0;
            var socket = new StandaloneWebSocket(() -> {
                set(session, "running", false);
                throw new java.io.IOException("test read complete");
            });
            StandaloneWebSocket.next = () -> {
                if (StandaloneWebSocket.attempts == 1) {
                    android.os.SystemClock.now = 0;
                    throw new RelayHTTPException(401, "call authentication failed");
                }
                return socket;
            };
            ((Runnable)session).run();
            check(StandaloneWebSocket.attempts == 2 && socket.closed, "temporary 401 must recover and clean socket");
            var retry = (CloudCallRetryPolicy.MediaRetry)field(session, "mediaRetry");
            check(retry.outcome(new RelayHTTPException(401, ""), 4, 120_000) == CloudCallRetryPolicy.MediaOutcome.RECONNECT,
                    "real successful handshake must reset unauthorized history");
        } finally { StandaloneWebSocket.next = null; }
    }

    private static void pendingDialBindsOnlyUniqueNewMatchingCall() throws Exception {
        var old = new android.telecom.Call(4, 1, "5550100");
        String oldID = CallRepository.add(old);
        var observation = CallRepository.observeOutgoing("5550100");
        var other = new android.telecom.Call(1, 1, "5550199");
        String otherID = CallRepository.add(other);
        var created = new android.telecom.Call(1, 1, "5550100");
        String createdID = CallRepository.add(created);
        try (var f = new Fixture("")) {
            set(f.descriptor, "outgoingObservation", observation);
            f.manager.handleCallEvent(registration(), event(oldID, "outgoing", "ended"), f.relay);
            check(createdID.equals(f.boundID()) && f.relay.states.isEmpty(), "bind only newly created matching call, ignore old end");
            f.manager.handleCallEvent(registration(), event(otherID, "outgoing", "active"), f.relay);
            check(f.relay.states.isEmpty(), "different-number call cannot drive session");
            f.manager.handleCallEvent(registration(), event(createdID, "outgoing", "dialing"), f.relay);
            check(f.relay.states.size() == 1 && "connecting".equals(f.relay.states.get(0).optString("phase")), "owned call must connect");
            CallRepository.remove(created);
            f.manager.handleCallEvent(registration(), event(createdID, "outgoing", "ended"), f.relay);
            check(f.active() == null, "bound call must close even after Telecom removes it");
        } finally {
            observation.close(); CallRepository.remove(old); CallRepository.remove(other); CallRepository.remove(created);
        }
    }

    private static void cachedDialCannotRecreateEndedSession() throws Exception {
        var context = new android.content.Context();
        context.setSystemService(android.app.role.RoleManager.class, new android.app.role.RoleManager());
        var created = new android.telecom.Call(1, 1, "5550100");
        var telecom = new android.telecom.TelecomManager() {
            @Override public void placeCall(android.net.Uri number, android.os.Bundle extras) {
                super.placeCall(number, extras); CallRepository.add(created);
            }
        };
        context.setSystemService(android.telecom.TelecomManager.class, telecom);
        var ctor = StandaloneAgentGateway.class.getDeclaredConstructor(android.content.Context.class);
        ctor.setAccessible(true);
        var gateway = ctor.newInstance(context);
        Field singleton = StandaloneCloudMediaManager.class.getDeclaredField("instance"); singleton.setAccessible(true);
        Object previous = singleton.get(null);
        try (var f = new Fixture("")) {
            var executor = new QueuedExecutor();
            set(f.manager, "sessions", executor);
            singleton.set(null, f.manager);
            var call = new JSONObject().put("call_id", "dial-cloud-call").put("call_uuid", "22222222-2222-4222-8222-222222222222")
                    .put("call_secret", "synthetic-secret").put("relay_url", "https://example.invalid");
            var command = new JSONObject().put("command_id", "33333333-3333-4333-8333-333333333333")
                    .put("type", "dial").put("number", "5550100").put("call", call);
            RelayEgressGate.shared.disableAndDrain(1000);
            var denied = gateway.executeCloudCommand(command);
            check("failed".equals(denied.optString("status")) && telecom.dialCount == 0 && executor.tasks == 0,
                    "late cloud command must not dial or create media in pure local");
            RelayEgressGate.shared.enableAfterRestore();
            var first = gateway.executeCloudCommand(command);
            check("completed".equals(first.optString("status")), "synthetic dial must succeed: " + first);
            check(executor.tasks == 1, "successful dial must schedule media once");
            check(CallRepository.id(created).equals(field(field(f.active(), "descriptor"), "androidID")), "dial must capture actual new Telecom call");
            f.manager.close();
            var replay = gateway.executeCloudCommand(command);
            check("completed".equals(replay.optString("status")) && telecom.dialCount == 1, "cached dial must not redial");
            check(executor.tasks == 1 && f.active() == null, "cached dial must not resurrect media");
        } finally { singleton.set(null, previous); CallRepository.remove(created); }
    }

    static final class QueuedExecutor extends java.util.concurrent.AbstractExecutorService {
        int tasks;
        public void execute(Runnable command) { tasks++; }
        public void shutdown() {}
        public java.util.List<Runnable> shutdownNow() { return java.util.List.of(); }
        public boolean isShutdown() { return false; }
        public boolean isTerminated() { return false; }
        public boolean awaitTermination(long time, java.util.concurrent.TimeUnit unit) { return true; }
    }

    private static void lateOutgoingCannotBindUnownedSession(String state) throws Exception {
        try (var f = new Fixture("")) {
            f.manager.handleCallEvent(registration(), event("previous-call", "outgoing", state), f.relay);
            check(f.relay.states.isEmpty(), "late " + state + " must not be submitted as new call");
            check(f.active() != null, "late " + state + " must not close new call");
            check(f.boundID().isEmpty(), "late " + state + " must not bind old Telecom ID");
        }
    }

    private static void otherCallCannotEndOwnedSession() throws Exception {
        try (var f = new Fixture("owner")) {
            f.manager.handleCallEvent(registration(), event("waiting", "incoming", "ended"), f.relay);
            check(f.relay.states.isEmpty() && f.active() != null, "waiting call cannot affect owner");
        }
    }

    private static void ownEndedClosesSession() throws Exception {
        try (var f = new Fixture("owner")) {
            f.manager.handleCallEvent(registration(), event("owner", "outgoing", "ended"), f.relay);
            check(f.active() == null && f.relay.states.size() == 1, "owner ended must close and notify");
            check("new-cloud-call".equals(f.relay.states.get(0).optString("call_id")), "Relay identity must stay fixed");
        }
    }

    private static void droppedEndedClosesOnlyOwner() throws Exception {
        try (var f = new Fixture("owner")) {
            f.manager.abandonCallEvent(event("other", "incoming", "ended").toString());
            check(f.active() != null, "dropping another call cannot close owner");
            f.manager.abandonCallEvent(event("owner", "incoming", "ended").toString());
            check(f.active() == null, "dropping owner's end must release it");
            check(f.relay.states.isEmpty(), "abandon must never send another HTTP request");
        }
    }

    static JSONObject event(String id, String direction, String state) throws Exception {
        return new JSONObject().put("call_id", id).put("direction", direction).put("state", state);
    }
    static JSONObject registration() throws Exception {
        return new JSONObject().put("device_id", "test-device").put("android_agent_id", "test-agent")
                .put("device_secret", "synthetic-secret");
    }
    static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    static Object field(Object object, String name) throws Exception {
        Field field = object.getClass().getDeclaredField(name); field.setAccessible(true); return field.get(object);
    }
    static void set(Object object, String name, Object value) throws Exception {
        Field field = object.getClass().getDeclaredField(name); field.setAccessible(true); field.set(object, value);
    }

    static final class Fixture implements AutoCloseable {
        final StandaloneCloudMediaManager manager;
        final Object descriptor;
        final StandaloneRelayClient relay = new StandaloneRelayClient();
        Fixture(String androidID) throws Exception {
            var constructor = StandaloneCloudMediaManager.class.getDeclaredConstructor(android.content.Context.class);
            constructor.setAccessible(true);
            manager = constructor.newInstance(new android.content.Context());
            var type = Class.forName("com.airsim.phonecontrol.StandaloneCloudMediaManager$Descriptor");
            var descriptorConstructor = type.getDeclaredConstructors()[0]; descriptorConstructor.setAccessible(true);
            descriptor = descriptorConstructor.newInstance("new-cloud-call", "11111111-1111-4111-8111-111111111111", 1L,
                    "synthetic-secret", "https://example.invalid", "outgoing", androidID);
            var sessionType = Class.forName("com.airsim.phonecontrol.StandaloneCloudMediaManager$CloudSession");
            var sessionConstructor = sessionType.getDeclaredConstructors()[0]; sessionConstructor.setAccessible(true);
            set(manager, "active", sessionConstructor.newInstance(manager, descriptor));
        }
        Object active() throws Exception { return field(manager, "active"); }
        String boundID() throws Exception { return (String)field(descriptor, "androidID"); }
        public void close() { manager.close(); }
    }
}
