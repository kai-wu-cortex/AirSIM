package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.lang.reflect.*;

/** Runs the actual manager without starting a socket, dial, or background executor. */
public final class CloudCallManagerTests {
    public static void main(String[] args) throws Exception {
        incomingIdentityUsesTelecomUUID();
        missedCallHistoryKeepsConnectionAndSIMFacts();
        RelayEgressGate.shared.enableAfterRestore();
        localResolveRequiresCompleteIdentityAndCurrentPublishedCall();
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
        outgoingAnswerPreparesMediaWithoutAnsweringTelecom();
        pendingAnswerCanRecoverWithSameIntent();
        answerIdentityExpiryAndTerminalAreRechecked();
        incomingAnswerDoesNotRepeatUnknownSideEffect();
        incomingAnswerSuccessIsDeduplicated();
        answerSocketReplayDoesNotRestartMedia();
        cloudEarlyMediaTransitionsOnlyOnTelecomActive();
        System.out.println("CloudCallManagerTests passed");
    }

    private static JSONObject answerCommand() throws Exception {
        return new JSONObject().put("command_id", "44444444-4444-4444-8444-444444444444")
                .put("type", "call_control").put("action", "answer")
                .put("call", new JSONObject().put("call_id", "new-cloud-call")
                        .put("call_uuid", "11111111-1111-4111-8111-111111111111").put("generation", 1));
    }

    private static void outgoingAnswerPreparesMediaWithoutAnsweringTelecom() throws Exception {
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100") {
            @Override public void answer(int videoState) { throw new AssertionError("outgoing must never answer Telecom"); }
        };
        String id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            var command = answerCommand();
            var result = g.gateway.executeCloudCommand(command);
            check("completed".equals(result.optString("status")), "DIALING must prepare media: " + result);
            check(call.getState() == android.telecom.Call.STATE_DIALING, "media ACK must not fake ACTIVE");
            check(result.getJSONObject("result").optBoolean("media_prepared")
                    && !result.getJSONObject("result").optBoolean("answered"), "outgoing ACK is not a carrier answer");
            for (int state : new int[]{android.telecom.Call.STATE_CONNECTING, android.telecom.Call.STATE_SELECT_PHONE_ACCOUNT}) {
                call.setStateForTest(state);
                check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "outgoing preparation state " + state);
            }
            call.setStateForTest(android.telecom.Call.STATE_ACTIVE);
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "same intent recovers after ACTIVE");
        } finally { CallRepository.remove(call); }
    }

    private static void pendingAnswerCanRecoverWithSameIntent() throws Exception {
        var observation = CallRepository.observeOutgoing("5550100");
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100");
        try (var f = new Fixture(""); var g = new GatewayFixture(f)) {
            set(f.descriptor, "outgoingObservation", observation);
            var command = answerCommand();
            check("call_not_ready".equals(g.gateway.executeCloudCommand(command).optString("error")), "before Telecom binding must be pending");
            CallRepository.add(call);
            set(f.manager, "sessions", new QueuedExecutor());
            var socket = controlSocket(mediaAnswer(command)); set(f.active(), "webSocket", socket);
            readControl(f.active(), socket);
            check(socket.text.stream().anyMatch(v -> v.contains("answer_ok")), "failed HTTP preparation must recover through in-band same ID");
            check(CallRepository.id(call).equals(f.boundID()), "must bind only the observed outgoing call");
        } finally { observation.close(); CallRepository.remove(call); }
    }

    private static void answerIdentityExpiryAndTerminalAreRechecked() throws Exception {
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100");
        String id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            var command = answerCommand();
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "preparation baseline");
            for (String field : new String[]{"call_id", "call_uuid", "generation"}) {
                var altered = new JSONObject(command.toString());
                altered.getJSONObject("call").put(field, field.equals("generation") ? 2 : "other-call");
                check("failed".equals(g.gateway.executeCloudCommand(altered).optString("status")), "same ID cannot change " + field);
                altered.put("command_id", java.util.UUID.randomUUID().toString());
                check("call_mismatch".equals(g.gateway.executeCloudCommand(altered).optString("error")), "new ID cannot bypass " + field);
            }
            check("failed".equals(g.gateway.executeCloudCommand(command, () -> false).optString("status")), "stale config cannot replay ACK");
            RelayEgressGate.shared.disableAndDrain(1000);
            check("failed".equals(g.gateway.executeCloudCommand(command).optString("status")), "pure local denies media preparation");
            RelayEgressGate.shared.enableAfterRestore();
            // The prior media session belongs to the old egress generation.
            check("failed".equals(g.gateway.executeCloudCommand(command).optString("status")), "restore cannot revive old generation");
        } finally { CallRepository.remove(call); RelayEgressGate.shared.enableAfterRestore(); }
        call = new android.telecom.Call(android.telecom.Call.STATE_ACTIVE, 1, "5550100"); id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            var command = answerCommand().put("expires_at", java.time.Instant.now().minusSeconds(1).toString());
            check("command_expired".equals(g.gateway.executeCloudCommand(command).optString("error")), "expired HTTP command");
            command.remove("expires_at");
            check("command_expired".equals(g.gateway.executeCloudCommand(command).optString("error")), "in-band cannot remove expiry");
            command.put("expires_at", java.time.Instant.now().plusSeconds(60).toString());
            check("command_expired".equals(g.gateway.executeCloudCommand(command).optString("error")), "same intent cannot extend expiry");
            command = answerCommand().put("command_id", java.util.UUID.randomUUID().toString());
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "active preparation");
            var attempts = (java.util.Map<?, ?>)field(g.gateway, "answerAttempts");
            set(attempts.get(command.getString("command_id")), "expiresAt", java.time.Instant.now().minusSeconds(1));
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")),
                    "confirmed live media can reconnect after the command execution deadline");
            call.setStateForTest(android.telecom.Call.STATE_DISCONNECTING);
            check("call_ended".equals(g.gateway.executeCloudCommand(command).optString("error")), "success cache cannot revive disconnecting call");
            CallRepository.remove(call);
            check("call_ended".equals(g.gateway.executeCloudCommand(command).optString("error")), "removed Telecom call cannot ACK");
        } finally { CallRepository.remove(call); }
    }

    private static void incomingAnswerSuccessIsDeduplicated() throws Exception {
        int[] answers = {0};
        var call = new android.telecom.Call(android.telecom.Call.STATE_RINGING, 0, "5550100") {
            @Override public void answer(int videoState) { answers[0]++; super.answer(videoState); }
        };
        String id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            set(f.descriptor, "direction", "incoming");
            var command = answerCommand();
            // A client-supplied direction cannot turn a real incoming answer into a no-op.
            command.getJSONObject("call").put("direction", "outgoing");
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "incoming must actually answer");
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")) && answers[0] == 1, "incoming duplicate must not re-answer");
            var end = new JSONObject(command.toString()).put("command_id", java.util.UUID.randomUUID().toString()).put("action", "end");
            check("completed".equals(g.gateway.executeCloudCommand(end).optString("status")), "ordinary hangup still succeeds");
            check("call_ended".equals(g.gateway.executeCloudCommand(command).optString("error")), "late incoming ACK cannot resurrect");
        } finally { CallRepository.remove(call); }
    }

    private static void incomingAnswerDoesNotRepeatUnknownSideEffect() throws Exception {
        int[] answers = {0};
        var call = new android.telecom.Call(android.telecom.Call.STATE_RINGING, 0, "5550100") {
            @Override public void answer(int videoState) { answers[0]++; throw new IllegalStateException("synthetic uncertain dispatch"); }
        };
        String id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            set(f.descriptor, "direction", "incoming");
            var command = answerCommand();
            check("failed".equals(g.gateway.executeCloudCommand(command).optString("status")), "incoming uncertain dispatch");
            check("failed".equals(g.gateway.executeCloudCommand(command).optString("status")) && answers[0] == 1, "unknown answer cannot blindly repeat");
            call.setStateForTest(android.telecom.Call.STATE_ACTIVE);
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")) && answers[0] == 1, "later ACTIVE confirms same intent without second answer");
        } finally { CallRepository.remove(call); }
    }

    private static StandaloneWebSocket controlSocket(JSONObject... commands) throws Exception {
        int[] index = {0};
        return new StandaloneWebSocket(() -> {
            if (index[0] == commands.length) throw new java.io.EOFException("fixture exhausted");
            return new StandaloneWebSocket.Message(1, commands[index[0]++].toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
        });
    }

    private static JSONObject mediaAnswer(JSONObject command) throws Exception {
        return new JSONObject(command.getJSONObject("call").toString())
                .put("command_id", command.getString("command_id")).put("action", "answer")
                .put("early_media_version", 1);
    }

    private static void readControl(Object session, StandaloneWebSocket socket) throws Exception {
        var read = session.getClass().getDeclaredMethod("readLoop", StandaloneWebSocket.class); read.setAccessible(true);
        try { read.invoke(session, socket); }
        catch (InvocationTargetException error) {
            if (!(error.getCause() instanceof java.io.EOFException)) throw error;
        }
    }

    private static void answerSocketReplayDoesNotRestartMedia() throws Exception {
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100");
        String id = CallRepository.add(call);
        try (var f = new Fixture(id); var g = new GatewayFixture(f)) {
            var executor = new QueuedExecutor(); set(f.manager, "sessions", executor);
            var command = answerCommand();
            // First entry is the HTTP/command-channel gateway; the media retry shares its ID.
            check("completed".equals(g.gateway.executeCloudCommand(command).optString("status")), "HTTP preparation");
            Object session = f.active();
            var legacy = mediaAnswer(command); legacy.remove("early_media_version");
            var socket = controlSocket(legacy, legacy); set(session, "webSocket", socket);
            readControl(session, socket);
            check(socket.text.stream().filter(v -> v.contains("answer_ok")).count() == 2, "media duplicate ACK");
            check(!(boolean)field(session, "earlyMediaAccepted"), "legacy client must not enable early media");
            check(executor.tasks == 1, "duplicate answer must not spawn another PCM loop");
            // Match the real reconnect loop, which clears mediaStarted for a new socket.
            set(session, "mediaStarted", false);
            var attempts = (java.util.Map<?, ?>)field(g.gateway, "answerAttempts");
            set(attempts.get(command.getString("command_id")), "expiresAt", java.time.Instant.now().minusSeconds(1));
            socket = controlSocket(mediaAnswer(command)); set(session, "webSocket", socket);
            readControl(session, socket);
            check(socket.text.stream().anyMatch(v -> v.contains("answer_ok")) && executor.tasks == 2,
                    "same confirmed ID restores the new media socket after command expiry");
            call.setStateForTest(android.telecom.Call.STATE_DISCONNECTED);
            var late = controlSocket(mediaAnswer(command)); set(session, "webSocket", late);
            readControl(session, late);
            check(late.text.stream().noneMatch(v -> v.contains("answer_ok")) && executor.tasks == 2, "late success cannot restart media");
        } finally { CallRepository.remove(call); }
    }

    static final class GatewayFixture implements AutoCloseable {
        final Field mediaSingleton, gatewaySingleton;
        final Object previousMedia, previousGateway;
        final StandaloneAgentGateway gateway;
        GatewayFixture(Fixture f) throws Exception {
            mediaSingleton = StandaloneCloudMediaManager.class.getDeclaredField("instance"); mediaSingleton.setAccessible(true);
            gatewaySingleton = StandaloneAgentGateway.class.getDeclaredField("instance"); gatewaySingleton.setAccessible(true);
            previousMedia = mediaSingleton.get(null); previousGateway = gatewaySingleton.get(null);
            var context = new android.content.Context();
            context.setSystemService(android.app.role.RoleManager.class, new android.app.role.RoleManager());
            var ctor = StandaloneAgentGateway.class.getDeclaredConstructor(android.content.Context.class); ctor.setAccessible(true);
            gateway = ctor.newInstance(context);
            mediaSingleton.set(null, f.manager); gatewaySingleton.set(null, gateway);
        }
        public void close() throws Exception {
            mediaSingleton.set(null, previousMedia); gatewaySingleton.set(null, previousGateway);
        }
    }

    private static void incomingIdentityUsesTelecomUUID() throws Exception {
        String id = java.util.UUID.randomUUID().toString();
        var registration = new JSONObject().put("relay_url", "https://relay.example.test");
        var descriptor = Class.forName("com.airsim.phonecontrol.StandaloneCloudMediaManager$Descriptor");
        var incoming = descriptor.getDeclaredMethod("incoming", JSONObject.class, String.class);
        incoming.setAccessible(true);
        var first = incoming.invoke(null, registration, id);
        var second = incoming.invoke(null, registration, id);
        check(id.equals(field(first, "callID")) && id.equals(field(first, "callUUID")), "LAN and APNs share Telecom UUID");
        check(field(first, "callUUID").equals(field(second, "callUUID")), "Recreating descriptor cannot split one carrier call");
        var legacy = incoming.invoke(null, registration, "legacy-id");
        check(field(legacy, "callID").equals("legacy-id"), "Legacy control identity stays unchanged");
        check(java.util.UUID.fromString((String) field(legacy, "callUUID")) != null, "Legacy still gets valid CallKit UUID");
    }

    private static void cloudEarlyMediaTransitionsOnlyOnTelecomActive() throws Exception {
        RuntimeMode.standalone = true;
        var call = new android.telecom.Call(android.telecom.Call.STATE_DIALING, 1, "5550100");
        String id = CallRepository.add(call);
        var threads = java.util.concurrent.Executors.newCachedThreadPool();
        var hellos = new java.util.concurrent.CopyOnWriteArrayList<String>();
        try (var f = new Fixture(id); var g = new GatewayFixture(f);
             var server = new java.net.ServerSocket(0, 2, java.net.InetAddress.getLoopbackAddress())) {
            set(f.manager, "pcmEndpoint", new java.net.InetSocketAddress(server.getInetAddress(), server.getLocalPort()));
            set(f.manager, "sessions", new QueuedExecutor());
            Object session = f.active();
            var owner = controlSocket(mediaAnswer(answerCommand()));
            set(session, "webSocket", owner);
            var eligible = session.getClass().getDeclaredMethod("earlyEligible"); eligible.setAccessible(true);
            check(!(boolean)eligible.invoke(session), "old client cannot open early media");
            readControl(session, owner);
            check((boolean)field(session, "mediaStarted") && owner.text.stream().anyMatch(v -> v.contains("answer_ok")),
                    "real gateway handshake must start media while DIALING");
            // The queued start keeps the fixture deterministic; PCM pump workers
            // below use real threads after the real control path has admitted it.
            set(f.manager, "sessions", threads);
            check((boolean)eligible.invoke(session), "generic standalone outgoing is eligible");
            var other = new android.telecom.Call(android.telecom.Call.STATE_RINGING, 0, "5550199");
            CallRepository.add(other);
            check(!(boolean)eligible.invoke(session), "global carrier source cannot mix a second call");
            CallRepository.remove(other);
            threads.submit(() -> {
                try {
                    for (int index=0; index<2; index++) {
                        final java.net.Socket socket = server.accept();
                        threads.submit(() -> {
                            try (socket) {
                                hellos.add(new String(socket.getInputStream().readNBytes(11), java.nio.charset.StandardCharsets.US_ASCII));
                                socket.getOutputStream().write("AIRSIMREADY".getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                                for (int n=0;n<100;n++) {
                                    socket.getOutputStream().write(new byte[320]); socket.getOutputStream().flush(); Thread.sleep(20);
                                }
                            } catch (Exception expectedOnClose) {}
                        });
                    }
                } catch (Exception expectedOnClose) {}
            });
            var run = session.getClass().getDeclaredMethod("runPCM", StandaloneWebSocket.class); run.setAccessible(true);
            var pump = threads.submit(() -> { try { run.invoke(session, owner); } catch (Exception e) { throw new RuntimeException(e); } });
            await(() -> owner.frames.get()>0, "early downlink frame");
            check(hellos.get(0).equals("AIRSIMRX01\n"), "early bridge must be recvonly");
            check(owner.text.stream().anyMatch(v -> v.contains("early_media_ready_v1")), "capability ACK required");
            check(owner.text.stream().noneMatch(v -> v.contains("\"status\":\"active\"")), "PCM READY cannot manufacture ACTIVE");
            call.setStateForTest(android.telecom.Call.STATE_ACTIVE);
            await(() -> hellos.size()==2 && owner.text.stream().anyMatch(v -> v.contains("\"status\":\"active\"")), "active duplex transition");
            check(hellos.get(1).equals("AIRSIMPCM1\n"), "active must reopen duplex bridge");
            ((java.io.Closeable)session).close();
            pump.get(3, java.util.concurrent.TimeUnit.SECONDS);
            check(field(session, "pcm")==null, "terminal must release bridge");
        } finally { CallRepository.remove(call); RuntimeMode.standalone=false; threads.shutdownNow(); threads.awaitTermination(3, java.util.concurrent.TimeUnit.SECONDS); }
    }
    private static void await(java.util.function.BooleanSupplier ready, String description) throws Exception {
        long until=System.nanoTime()+3_000_000_000L;
        while(!ready.getAsBoolean() && System.nanoTime()<until) Thread.sleep(10);
        check(ready.getAsBoolean(), description);
    }

    private static void localResolveRequiresCompleteIdentityAndCurrentPublishedCall() throws Exception {
        var instance = StandaloneCloudMediaManager.class.getDeclaredField("instance");
        instance.setAccessible(true);
        Object previous = instance.get(null);
        var owner = new android.telecom.Call(android.telecom.Call.STATE_RINGING, 0, "5550100");
        String ownerID = CallRepository.add(owner);
        try (var f = new Fixture(ownerID)) {
            instance.set(null, f.manager);
            var constructor = StandaloneAgentGateway.class.getDeclaredConstructor(android.content.Context.class);
            constructor.setAccessible(true);
            var gateway = constructor.newInstance(new android.content.Context());
            var published = new JSONObject().put("id", "local-owner").put("android_id", ownerID)
                    .put("state", "incoming");
            set(gateway, "activeCall", published);
            var identity = new JSONObject().put("call_id", "new-cloud-call")
                    .put("call_uuid", "11111111-1111-4111-8111-111111111111").put("generation", "1");
            var response = gateway.forward("POST", "/api/calls/resolve", identity.toString());
            check(response.status() == 200 && "local-owner".equals(new JSONObject(response.payload())
                    .getJSONObject("active").getString("id")), "resolve must return the owned local identity");
            for (String key : new String[] { "call_id", "call_uuid", "generation" }) {
                var incomplete = new JSONObject(identity.toString()); incomplete.remove(key);
                check(gateway.forward("POST", "/api/calls/resolve", incomplete.toString()).status() == 409,
                        "missing identity field accepted: " + key);
            }
            for (String key : new String[] { "call_id", "call_uuid", "generation" }) {
                var stale = new JSONObject(identity.toString()); stale.put(key, "2");
                check(gateway.forward("POST", "/api/calls/resolve", stale.toString()).status() == 409,
                        "incorrect identity field accepted: " + key);
            }
            for (Object generation : new Object[] { JSONObject.NULL, true, 1.5, "bad", "9223372036854775808", "0", "-1" }) {
                var invalid = new JSONObject(identity.toString()); invalid.put("generation", generation);
                check(gateway.forward("POST", "/api/calls/resolve", invalid.toString()).status() == 409,
                        "invalid generation accepted: " + generation);
            }
            published.put("android_id", "replacement-call");
            check(gateway.forward("POST", "/api/calls/resolve", identity.toString()).status() == 409,
                    "old mapping resolved replacement call");
            set(gateway, "activeCall", null);
            check(gateway.forward("POST", "/api/calls/resolve", identity.toString()).status() == 409,
                    "ended mapping still resolved");
        } finally { instance.set(null, previous); CallRepository.remove(owner); }
    }

    private static void missedCallHistoryKeepsConnectionAndSIMFacts() throws Exception {
        var ctor = StandaloneAgentGateway.class.getDeclaredConstructor(android.content.Context.class);
        ctor.setAccessible(true);
        var gateway = ctor.newInstance(new android.content.Context());
        var apply = StandaloneAgentGateway.class.getDeclaredMethod("applyCallEvent", JSONObject.class);
        apply.setAccessible(true);
        var history = StandaloneAgentGateway.class.getDeclaredField("callHistory"); history.setAccessible(true);
        for (int index = 0; index < 3; index++) {
            String direction = index == 2 ? "outgoing" : "incoming";
            var event = new JSONObject().put("call_id", "history-" + index).put("direction", direction)
                    .put("state", index == 2 ? "dialing" : "incoming").put("slot_index", index % 2);
            apply.invoke(gateway, event);
            if (index == 1) apply.invoke(gateway, new JSONObject(event.toString()).put("state", "active"));
            apply.invoke(gateway, new JSONObject(event.toString()).put("state", "ended"));
        }
        var replacement = new JSONObject().put("call_id", "replacement").put("direction", "incoming").put("state", "incoming");
        apply.invoke(gateway, replacement);
        apply.invoke(gateway, new JSONObject().put("call_id", "history-0").put("state", "ended"));
        check(field(gateway, "activeCall") != null, "late terminal cleared replacement call");
        var records = (org.json.JSONArray) history.get(gateway);
        check(records.length() == 3, "late terminal wrote false history");
        check(records.getJSONObject(0).optBoolean("missed"), "unanswered incoming missing from history");
        check(!records.getJSONObject(1).optBoolean("missed") && records.getJSONObject(1).has("connected_at"), "answered call marked missed");
        check(!records.getJSONObject(2).optBoolean("missed"), "outgoing call marked missed");
        check(records.getJSONObject(0).optInt("slot_index", -1) == 0 && records.getJSONObject(1).optInt("slot_index", -1) == 1, "history lost SIM slots");
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
            var sessionConstructor = sessionType.getDeclaredConstructor(StandaloneCloudMediaManager.class, type); sessionConstructor.setAccessible(true);
            set(manager, "active", sessionConstructor.newInstance(manager, descriptor));
        }
        Object active() throws Exception { return field(manager, "active"); }
        String boundID() throws Exception { return (String)field(descriptor, "androidID"); }
        public void close() { manager.close(); }
    }
}
