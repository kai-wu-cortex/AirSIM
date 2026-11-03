package com.airsim.phonecontrol;

import android.app.role.RoleManager;
import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/** In-process replacement for the HTTP API previously hosted by the AVF Agent. */
final class StandaloneAgentGateway {
    private static volatile StandaloneAgentGateway instance;

    static StandaloneAgentGateway get(Context context) {
        StandaloneAgentGateway value = instance;
        if (value == null) {
            synchronized (StandaloneAgentGateway.class) {
                value = instance;
                if (value == null) instance = value = new StandaloneAgentGateway(context);
            }
        }
        return value;
    }

    private final Context context;
    private final StandaloneAgentStore store;
    private final StandaloneSMSStore smsStore;
    private final Object callsLock = new Object();
    private final Object commandsLock = new Object();
    private final StandaloneLongPoll callEvents = new StandaloneLongPoll();
    private final StandaloneLongPoll agentEvents = new StandaloneLongPoll();
    private volatile long simRevision;
    private final Map<String, String> commandResults = new LinkedHashMap<>();
    private JSONObject activeCall;
    private final JSONArray callHistory = new JSONArray();

    private StandaloneAgentGateway(Context context) {
        this.context = context.getApplicationContext();
        store = new StandaloneAgentStore(context);
        smsStore = new StandaloneSMSStore(context);
    }

    String health() throws Exception {
        return new JSONObject().put("ok", true).put("product", "airsim")
                .put("version", "standalone-0.1.0").put("runtime_profile", "android-standalone")
                .put("sim_slots", SimSlotJson.slots(context))
                .toString();
    }

    String status() throws Exception {
        return new JSONObject().put("ok", true).put("configured", store.configured())
                .put("runtime_profile", "android-standalone").put("pending_commands", 0)
                .put("last_seen", store.lastSeen() == 0 ? "" : Instant.ofEpochMilli(store.lastSeen()).toString())
                .put("transport", "in_process").toString();
    }

    String pushStatus() throws Exception { return store.pushStatus().toString(); }

    String registrationSnapshot() { JSONObject value = store.registration(); return value == null ? "" : value.toString(); }
    void restoreRegistrationSnapshot(String snapshot) throws Exception { store.restoreSnapshot(snapshot); }
    void discardCloudBacklog() throws Exception { smsStore.discardCloudBacklog(); }

    String debugSnapshot() throws Exception {
        return new JSONObject().put("events", new JSONArray()).put("runtime_profile", "android-standalone")
                .put("log_available_in_app", true).toString();
    }

    String feedbackSnapshot() throws Exception {
        String log = BridgeLog.read();
        return new JSONObject()
                .put("runtime_profile", "android-standalone")
                .put("bridge_log", log)
                .put("manufacturer", android.os.Build.MANUFACTURER)
                .put("model", android.os.Build.MODEL)
                .put("sdk", android.os.Build.VERSION.SDK_INT)
                .put("app_version", AppInformation.version(context))
                .put("audio", new JSONObject()
                        .put("telecom_state", CallRepository.diagnosticState())
                        .put("pcm_client_closed", log.contains("pcm_event=client_closed"))
                        .put("pcm_health", latestPcmHealth(log)))
                .toString();
    }

    private static String latestPcmHealth(String log) {
        String latest = "";
        for (String line : log.split("\n")) {
            if (line.contains("pcm_health")) latest = line;
        }
        return latest.length() > 1200 ? latest.substring(0, 1200) : latest;
    }

    String registerPairing(String registrationJSON) throws Exception {
        JSONObject registration = store.saveRegistration(registrationJSON);
        ForwardingConfigStore.saveFromRegistration(context, registration);
        StandaloneAgentService.start(context);
        if (registration.optBoolean("local_mode", false)) {
            BridgeLog.info("standalone_local_pairing_saved");
            return new JSONObject().put("configured", true).put("local_mode", true).toString();
        }
        String deviceID = registration.getString("device_id");
        String hint = deviceID.length() <= 8 ? deviceID : "…" + deviceID.substring(deviceID.length() - 8);
        BridgeLog.info("standalone_pairing_saved device_id_hint=" + DebugRedactor.safeIdentifier(hint));
        return new JSONObject().put("configured", true).put("device_id_hint", hint).toString();
    }

    void sendCallEvent(String json) throws Exception {
        JSONObject event = new JSONObject(json);
        NotificationForwarder.handle(context, event);
        applyCallEvent(event);
        if (store.configured() && store.cloudEnabled()) {
            StandaloneAgentService.enqueueCallEvent(context, event.toString());
        }
    }

    void sendSMSEvent(String json) throws Exception {
        JSONObject event = new JSONObject(json);
        NotificationForwarder.handle(context, event);
        com.airsim.phonecontrol.voble.VoBLEGatewayService.publishSMS(context, event);
        if (smsStore.add(event, store.configured() && store.cloudEnabled())) {
            agentEvents.advance();
            if (store.configured() && store.cloudEnabled()) StandaloneAgentService.start(context);
        }
    }

    AgentClient.ForwardResponse forward(String method, String pathAndQuery, String body) throws Exception {
        int query = pathAndQuery.indexOf('?');
        String path = query < 0 ? pathAndQuery : pathAndQuery.substring(0, query);
        if ("GET".equalsIgnoreCase(method)) {
            return switch (path) {
                case "/api/health" -> ok(health());
                case "/api/android/status", "/api/status" -> ok(status());
                case "/api/push/status" -> ok(pushStatus());
                case "/api/debug" -> ok(debugSnapshot());
                case "/api/feedback" -> ok(feedbackSnapshot());
                case "/api/calls/status" -> ok(callSnapshot().toString());
                case "/api/calls/events" -> waitForCallEvent(pathAndQuery);
                case "/api/events" -> waitForAgentEvent(pathAndQuery);
                case "/api/sms" -> ok(smsStore.localMessages().toString());
                case "/api/sms/status" -> ok(new JSONObject().put("auto_cleanup_me", true)
                        .put("count", smsStore.pendingCount()).put("last_poll_error", "").toString());
                case "/api/calls/audio/host/config" -> ok(new JSONObject()
                        .put("transport", "tcp_pcm_s16le").put("host", "127.0.0.1")
                        .put("port", 7580).put("sample_rate", 8000).put("channels", 1)
                        .put("route_ready", true).put("route_listening", true).toString());
                default -> error(404, "not_found");
            };
        }
        if (!"POST".equalsIgnoreCase(method)) return error(405, "method_not_allowed");
        JSONObject input = body == null || body.isBlank() ? new JSONObject() : new JSONObject(body);
        return switch (path) {
            case "/api/push/register" -> ok(registerPairing(input.toString()));
            case "/api/push/mode" -> ok(store.setCloudEnabled(
                    input.optBoolean("enabled", false)).toString());
            case "/api/calls/dial" -> command("dial", "", input.optString("number", ""), "",
                    input.optString("sim_account", ""));
            case "/api/calls/answer" -> command("answer", localCallTarget("answer", input), "", "");
            case "/api/calls/reject" -> command("reject", localCallTarget("reject", input), "", "");
            case "/api/calls/hangup" -> command("end", localCallTarget("end", input), "", "");
            case "/api/calls/dtmf" -> command("dtmf", localCallTarget("dtmf", input), input.optString("digit", ""), "");
            case "/api/sms/send" -> command("send_sms", "", input.optString("phone", ""),
                    input.optString("message", ""), input.optString("sim_account", ""));
            case "/api/calls/history/ack" -> {
                JSONArray ids = input.optJSONArray("ids") == null ? new JSONArray() : input.getJSONArray("ids");
                synchronized (callsLock) {
                    for (int index = callHistory.length() - 1; index >= 0; index--) {
                        JSONObject record = callHistory.optJSONObject(index);
                        if (record == null) continue;
                        for (int id = 0; id < ids.length(); id++) {
                            String value = ids.optString(id, "");
                            if (!value.isEmpty() && (value.equals(record.optString("id"))
                                    || value.equals(record.optString("android_id"))
                                    || value.equals(record.optString("backend_id")))) {
                                callHistory.remove(index);
                                break;
                            }
                        }
                    }
                }
                yield ok("{\"accepted\":true}");
            }
            case "/api/calls/audio/host/warmup" -> ok("{\"warming\":true}");
            case "/api/calls/audio/host/register" -> ok(new JSONObject()
                    .put("enabled", input.optBoolean("enabled", false)).toString());
            case "/api/calls/audio/mute" -> ok(new JSONObject()
                    .put("muted", input.optBoolean("muted", false)).toString());
            case "/api/sms/ack" -> {
                smsStore.acknowledge(input.optJSONArray("ids") == null ? new JSONArray() : input.getJSONArray("ids"));
                yield ok("{\"accepted\":true}");
            }
            case "/api/sms/refresh" -> ok("{\"accepted\":true}");
            default -> error(404, "not_found");
        };
    }

    synchronized void simSlotsChanged() {
        simRevision++;
        agentEvents.advance();
    }

    synchronized JSONObject executeCloudCommand(JSONObject command) throws Exception {
        return executeCloudCommand(command,()->true);
    }

    synchronized JSONObject executeCloudCommand(JSONObject command, java.util.function.BooleanSupplier stillCurrent) throws Exception {
        RelayEgressGate.Lease lease;
        try { lease = RelayEgressGate.shared.acquire(() -> {}); }
        catch (java.io.IOException denied) {
            return new JSONObject().put("command_id", command.optString("command_id", ""))
                    .put("status", "failed").put("error", "pure_local_relay_disabled");
        }
        // Track the action as well as its HTTP/socket: an already dispatched operation
        // must finish before Android can acknowledge that the old generation drained.
        try (lease) {
            return executeAdmittedCloudCommand(command, () -> lease.isCurrent() && stillCurrent.getAsBoolean());
        }
    }

    private JSONObject executeAdmittedCloudCommand(JSONObject command, java.util.function.BooleanSupplier stillCurrent) throws Exception {
        String commandID = command.optString("command_id", "");
        if (!stillCurrent.getAsBoolean()) return new JSONObject().put("command_id",commandID)
                .put("status","failed").put("error","command_configuration_changed");
        String commandKey = commandID.trim().toLowerCase(Locale.ROOT);
        if (!commandKey.isEmpty()) {
            synchronized (commandsLock) {
                String cached = commandResults.get(commandKey);
                if (cached != null) return new JSONObject(cached);
            }
        }
        if (!commandID.matches("[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,36}")) {
            return new JSONObject().put("command_id", commandID).put("status", "failed")
                    .put("error", "云端命令 ID 无效");
        }
        String expires = command.optString("expires_at", "");
        if (!expires.isEmpty()) {
            try {
                if (Instant.now().isAfter(Instant.parse(expires))) {
                    return rememberCommand(commandKey, new JSONObject().put("command_id", commandID)
                            .put("status", "failed").put("error", "云端命令已过期"));
                }
            } catch (Exception invalidExpiry) {
                return rememberCommand(commandKey, new JSONObject().put("command_id", commandID)
                        .put("status", "failed").put("error", "云端命令有效期无效"));
            }
        }
        String type = command.optString("type", "");
        String action = switch (type) {
            case "dial" -> "dial";
            case "send_sms" -> "send_sms";
            case "dtmf" -> "dtmf";
            case "call_control" -> "rescue_hangup".equals(command.optString("action"))
                    ? "end" : command.optString("action", "");
            default -> "";
        };
        String callID = CloudCallTarget.requiresIdentity(type)
                ? StandaloneCloudMediaManager.get(context).androidCallIDFor(command.optJSONObject("call"))
                : "dial".equals(action) || "send_sms".equals(action)
                    ? "" : CallRepository.idForAction(action);
        if (CloudCallTarget.requiresIdentity(type) && callID.isBlank()) {
            return rememberCommand(commandKey,new JSONObject().put("command_id",commandID)
                    .put("status","failed").put("error","call_mismatch"));
        }
        AgentCommand local = new AgentCommand(commandID, action, callID,
                command.optString("number", ""), command.optString("message", ""),
                command.optString("sim_account", ""));
        var outgoing = "dial".equals(action) ? CallRepository.observeOutgoing(command.optString("number", "")) : null;
        boolean handedToMedia = false;
        try {
            if (!stillCurrent.getAsBoolean()) return new JSONObject().put("command_id", commandID)
                    .put("status", "failed").put("error", "command_configuration_changed");
            AgentCommandDispatcher.Result result = execute(local);
            JSONObject output = new JSONObject().put("command_id", commandID)
                    .put("status", result.success() ? "completed" : "failed");
            if (result.success()) {
                JSONObject detail = new JSONObject();
                if ("send_sms".equals(action)) detail.put("sent", true).put("segments", result.segments());
                else if ("dial".equals(action)) {
                    detail.put("dialing", true).put("android_confirmed", true);
                    // This uncached path runs once per command. Replayed completions must not
                    // restart media, replace its ownership observation, or resurrect ended calls.
                    StandaloneCloudMediaManager.get(context).startOutgoing(command.optJSONObject("call"), outgoing);
                    handedToMedia = true;
                }
                else if ("answer".equals(action)) detail.put("answered", true).put("android_confirmed", true);
                else if ("end".equals(action) || "reject".equals(action)) detail.put("ended", true).put("android_confirmed", true);
                else detail.put("sent", true);
                output.put("result", detail);
            } else {
                output.put("error", result.error());
            }
            return rememberCommand(commandKey, output);
        } finally {
            if (!handedToMedia && outgoing != null) outgoing.close();
        }
    }

    private JSONObject rememberCommand(String commandKey, JSONObject output) {
        if (commandKey.isEmpty()) return output;
        synchronized (commandsLock) {
            commandResults.put(commandKey, output.toString());
            while (commandResults.size() > 128) {
                commandResults.remove(commandResults.keySet().iterator().next());
            }
        }
        return output;
    }

    private AgentClient.ForwardResponse command(String action, String callID, String number, String message)
            throws Exception {
        return command(action, callID, number, message, "");
    }

    private AgentClient.ForwardResponse command(String action, String callID, String number, String message,
                                                String simAccount) throws Exception {
        AgentCommandDispatcher.Result result = execute(new AgentCommand(
                UUID.randomUUID().toString(), action, callID, number, message, simAccount));
        if (!result.success()) return error(502, result.error());
        JSONObject value = new JSONObject();
        switch (action) {
            case "dial" -> value.put("dialing", true).put("number", number).put("android_confirmed", true);
            case "answer" -> value.put("answered", true);
            case "reject" -> value.put("rejected", true);
            case "end" -> value.put("hung_up", true);
            case "dtmf" -> value.put("sent", true);
            case "send_sms" -> value.put("sent", true).put("segments", result.segments());
        }
        return ok(value.toString());
    }

    private String localCallTarget(String action, JSONObject input) {
        synchronized (callsLock) {
            return CallRepository.idForPublishedAction(action, input.optString("call_id"),
                    activeCall == null ? "" : activeCall.optString("id"),
                    activeCall == null ? "" : activeCall.optString("android_id"));
        }
    }

    private AgentCommandDispatcher.Result execute(AgentCommand command) {
        RoleManager roles = context.getSystemService(RoleManager.class);
        boolean dialer = roles != null && roles.isRoleHeld(RoleManager.ROLE_DIALER);
        return AgentCommandDispatcher.execute(command, dialer,
                value -> {
                    CallRepository.ActionResult result = CallRepository.execute(
                            context, value);
                    return new AgentCommandDispatcher.Result(result.success, result.error, 0);
                },
                value -> SMSCommandExecutor.execute(context, value));
    }

    private void applyCallEvent(JSONObject event) throws Exception {
        synchronized (callsLock) {
            String state = event.optString("state", "");
            if ("ended".equals(state)) {
                if (activeCall != null) {
                    activeCall.put("state", "ended").put("ended_at", Instant.now().toString())
                            .put("updated_at", Instant.now().toString());
                    callHistory.put(activeCall);
                    activeCall = null;
                }
            } else {
                if (activeCall == null || !event.optString("call_id").equals(activeCall.optString("android_id"))) {
                    activeCall = new JSONObject().put("id", "android-" + System.currentTimeMillis())
                            .put("android_id", event.optString("call_id")).put("index", 1)
                            .put("started_at", Instant.now().toString()).put("missed", false);
                }
                activeCall.put("direction", event.optString("direction"))
                        .put("state", state).put("number", event.optString("number"))
                        .put("updated_at", Instant.now().toString());
                if (event.has("slot_index")) {
                    activeCall.put("slot_index", event.optInt("slot_index", -1))
                            .put("slot_id", event.optInt("slot_id", event.optInt("slot_index", -1)));
                }
            }
        }
        callEvents.advance();
        agentEvents.advance();
    }

    private JSONObject callSnapshot() throws Exception {
        synchronized (callsLock) {
            return new JSONObject().put("active", activeCall == null ? JSONObject.NULL : activeCall)
                    .put("history", callHistory).put("polling", false).put("event_driven", true)
                    .put("poll_interval_s", 0).put("last_poll_error", "")
                    .put("revision", callEvents.revision());
        }
    }

    private AgentClient.ForwardResponse waitForCallEvent(String pathAndQuery) throws Exception {
        StandaloneLongPoll.Request request = StandaloneLongPoll.parse(pathAndQuery, 25_000);
        callEvents.awaitChange(request.after(), request.timeoutMillis());
        return ok(callSnapshot().toString());
    }

    private AgentClient.ForwardResponse waitForAgentEvent(String pathAndQuery) throws Exception {
        StandaloneLongPoll.Request request = StandaloneLongPoll.parse(pathAndQuery, 15_000);
        agentEvents.awaitChange(request.after(), request.timeoutMillis());
        return ok(new JSONObject().put("revision", agentEvents.revision())
                .put("sms_revision", smsStore.revision()).put("sms_pending", smsStore.pendingCount())
                .put("sim_revision", simRevision)
                .put("sim_slots", SimSlotJson.slots(context))
                .put("call", callSnapshot()).toString());
    }

    private static AgentClient.ForwardResponse ok(String body) { return new AgentClient.ForwardResponse(200, body); }
    private static AgentClient.ForwardResponse error(int status, String message) throws Exception {
        return new AgentClient.ForwardResponse(status, new JSONObject().put("error", message).toString());
    }
}
