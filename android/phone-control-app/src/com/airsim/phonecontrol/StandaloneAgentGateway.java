package com.airsim.phonecontrol;

import android.app.role.RoleManager;
import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;

import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
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
    private final StandaloneLongPoll clusterEvents = new StandaloneLongPoll();
    private static final int MAX_CLUSTER_EVENTS = 50;
    private final List<JSONObject> clusterEventsList = new ArrayList<>();
    private final Map<String, String> commandResults = new LinkedHashMap<>();
    private JSONObject activeCall;
    private final JSONArray callHistory = new JSONArray();

    private StandaloneAgentGateway(Context context) {
        this.context = context.getApplicationContext();
        store = new StandaloneAgentStore(context);
        smsStore = new StandaloneSMSStore(context);
        // 集群事件游标从 1 开始：保证 sync 事件永远返回 ≥1 的修订号，
        // 避免客户端以 after=0 重复请求造成紧密轮询死循环。
        clusterEvents.advance();
        SIMSlotManager.registerChangeListener(this.context, () -> {
            agentEvents.advance();
            try {
                publishClusterEvent(new JSONObject().put("type", "sim_status_changed"));
            } catch (Exception ignored) {}
        });
    }

    String health() throws Exception {
        return new JSONObject().put("ok", true).put("product", "airsim")
                .put("version", "standalone-0.1.0").put("runtime_profile", "android-standalone")
                .put("slots", SIMSlotManager.getSlotsJSON(context))
                .put("active_slots_count", SIMSlotManager.getActiveSlots(context).size())
                .toString();
    }

    String status() throws Exception {
        return new JSONObject().put("ok", true).put("configured", store.configured())
                .put("runtime_profile", "android-standalone").put("pending_commands", 0)
                .put("last_seen", store.lastSeen() == 0 ? "" : Instant.ofEpochMilli(store.lastSeen()).toString())
                .put("transport", "in_process")
                .put("slots", SIMSlotManager.getSlotsJSON(context))
                .put("active_slots_count", SIMSlotManager.getActiveSlots(context).size())
                .toString();
    }

    String pushStatus() throws Exception { return store.pushStatus().toString(); }

    String debugSnapshot() throws Exception {
        return new JSONObject().put("events", new JSONArray()).put("runtime_profile", "android-standalone")
                .put("log_available_in_app", true).toString();
    }

    String registerPairing(String registrationJSON) throws Exception {
        JSONObject registration = store.saveRegistration(registrationJSON);
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

    void clearPairing() {
        synchronized (commandsLock) {
            commandResults.clear();
        }
        synchronized (callsLock) {
            activeCall = null;
        }
        agentEvents.advance();
        callEvents.advance();
        clusterEvents.advance();
        BridgeLog.info("standalone_pairing_cleared");
    }

    void sendCallEvent(String json) throws Exception {
        JSONObject event = new JSONObject(json);
        applyCallEvent(event);
        clusterEvents.advance();
        if (store.configured() && store.cloudEnabled()) {
            StandaloneAgentService.enqueueCallEvent(context, event.toString());
        }
    }

    void sendSMSEvent(String json) throws Exception {
        JSONObject event = new JSONObject(json);
        if (smsStore.add(event, store.configured() && store.cloudEnabled())) {
            agentEvents.advance();
            JSONObject smsCluster = new JSONObject()
                    .put("type", "sms_received")
                    .put("sender", event.optString("sender", event.optString("address", "")))
                    .put("content", event.optString("content", event.optString("body", "")))
                    .put("code", event.optString("code", ""))
                    .put("slot_index", event.optInt("slot_id", 0));
            publishClusterEvent(smsCluster);
            if (store.configured() && store.cloudEnabled()) StandaloneAgentService.start(context);
        }
    }

    AgentClient.ForwardResponse forward(String method, String pathAndQuery, String body) throws Exception {
        int query = pathAndQuery.indexOf('?');
        String path = query < 0 ? pathAndQuery : pathAndQuery.substring(0, query);
        if ("GET".equalsIgnoreCase(method)) {
            return switch (path) {
                case "/api/health" -> ok(health());
                case "/api/android/status" -> ok(status());
                case "/api/push/status" -> ok(pushStatus());
                case "/api/debug" -> ok(debugSnapshot());
                case "/api/android/sims" -> ok(SIMSlotManager.getSlotsJSON(context).toString());
                case "/api/calls/status" -> ok(callSnapshot().toString());
                case "/api/calls/events" -> waitForCallEvent(pathAndQuery);
                case "/api/events" -> waitForAgentEvent(pathAndQuery);
                case "/api/v2/sims" -> ok(v2Sims().toString());
                case "/api/v2/sms" -> ok(v2Sms().toString());
                case "/api/v2/cluster/events" -> waitForClusterEvents(pathAndQuery);
                case "/api/sms" -> ok(smsStore.localMessages().toString());
                case "/api/sms/status" -> ok(new JSONObject().put("auto_cleanup_me", true)
                        .put("count", smsStore.pendingCount()).put("last_poll_error", "").toString());
                case "/api/calls/audio/host/config" -> ok(new JSONObject()
                        .put("transport", "tcp_pcm_s16le").put("host", "self")
                        .put("port", VoWLANGatewayService.activePcmPort()).put("sample_rate", 8000).put("channels", 1)
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
            case "/api/calls/dial" -> {
                String slotStr = input.optString("slot", "");
                int slotId = input.optInt("slot_id", SIMSlotManager.parseSlotIdentifier(slotStr));
                int subId = input.optInt("sub_id", -1);
                yield command("dial", "", input.optString("number", ""), "", slotId, subId, slotStr);
            }
            case "/api/calls/answer" -> command("answer", localCallTarget("answer", input), "", "");
            case "/api/calls/reject" -> command("reject", localCallTarget("reject", input), "", "");
            case "/api/calls/hangup" -> command("end", localCallTarget("end", input), "", "");
            case "/api/calls/dtmf" -> command("dtmf", CallRepository.idForAction("dtmf"), input.optString("digit", ""), "");
            case "/api/sms/send" -> {
                String slotStr = input.optString("slot", "");
                int slotId = input.optInt("slot_id", SIMSlotManager.parseSlotIdentifier(slotStr));
                int subId = input.optInt("sub_id", -1);
                yield command("send_sms", "", input.optString("phone", ""),
                        input.optString("message", ""), slotId, subId, slotStr);
            }
            case "/api/v2/calls/dial" -> {
                int slotIndex = input.optInt("slot_index", input.optInt("slot_id", -1));
                String slotStr = slotIndex >= 0 ? "slot" + slotIndex : input.optString("slot", "");
                int subId = input.optInt("sub_id", -1);
                String dialNumber = input.optString("number", "");
                String clientCallUUID = input.optString("call_uuid", input.optString("callUUID", ""));
                java.util.Set<String> beforeIDs = CallRepository.callIDs();
                AgentCommandDispatcher.Result result = execute(new AgentCommand(
                        UUID.randomUUID().toString(), "dial", "", dialNumber, "", slotIndex, subId, slotStr));
                if (!result.success()) yield error(502, result.error());
                // 等待 Telecom 层创建外呼 Call，把权威通话 ID 回传给 macOS 客户端，
                // 确保后续挂断/静音命令能命中同一通话（修复挂断不生效问题）。
                String createdID = CallRepository.newOutgoingCallSince(beforeIDs, dialNumber);
                long dialDeadline = System.nanoTime()
                        + java.util.concurrent.TimeUnit.SECONDS.toNanos(2);
                while (createdID.isEmpty() && System.nanoTime() < dialDeadline) {
                    Thread.sleep(50);
                    createdID = CallRepository.newOutgoingCallSince(beforeIDs, dialNumber);
                }
                if (!createdID.isEmpty()) rememberClientCallID(clientCallUUID, createdID);
                yield ok(new JSONObject()
                        .put("dialing", true)
                        .put("number", dialNumber)
                        .put("android_confirmed", true)
                        .put("call_uuid", createdID)
                        .put("call_id", createdID)
                        .put("audio_port", VoWLANGatewayService.activePcmPort())
                        .toString());
            }
            case "/api/v2/ring_group/answer" -> {
                String callUuid = input.optString("callUUID", input.optString("call_uuid", ""));
                String clientDeviceID = input.optString("clientDeviceID", input.optString("client_device_id", "macos"));
                command("answer", localCallTarget("answer", input), "", "");
                JSONObject answerResp = new JSONObject()
                        .put("callUUID", callUuid)
                        .put("call_uuid", callUuid)
                        .put("accepted", true)
                        .put("winnerDeviceID", clientDeviceID)
                        .put("winner_device_id", clientDeviceID)
                        .put("audioPort", VoWLANGatewayService.activePcmPort())
                        .put("audio_port", VoWLANGatewayService.activePcmPort())
                        .put("codec", "pcm");
                yield ok(answerResp.toString());
            }
            case "/api/v2/calls/hangup" -> command("end", localCallTarget("end", input), "", "");
            case "/api/v2/calls/reject" -> command("reject", localCallTarget("reject", input), "", "");
            case "/api/v2/sms/send" -> {
                int slotIndex = input.optInt("slot_index", input.optInt("slot_id", -1));
                String slotStr = slotIndex >= 0 ? "slot" + slotIndex : input.optString("slot", "");
                int subId = input.optInt("sub_id", -1);
                yield command("send_sms", "", input.optString("phone", ""),
                        input.optString("message", ""), slotIndex, subId, slotStr);
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

    synchronized JSONObject executeCloudCommand(JSONObject command) throws Exception {
        return executeCloudCommand(command,()->true);
    }

    synchronized JSONObject executeCloudCommand(JSONObject command, java.util.function.BooleanSupplier stillCurrent) throws Exception {
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
        // 上游 v0.9.7.2：云端命令必须命中权威通话 ID，避免迟到的命令误操作下一通电话。
        if (CloudCallTarget.requiresIdentity(type) && callID.isBlank()) {
            return rememberCommand(commandKey,new JSONObject().put("command_id",commandID)
                    .put("status","failed").put("error","call_mismatch"));
        }
        // LDev：DSDS 动态双卡聚合——支持按卡槽/订阅 ID 定向外呼与发短信。
        String slotStr = command.optString("slot", "");
        int slotId = command.optInt("slot_id", SIMSlotManager.parseSlotIdentifier(slotStr));
        int subId = command.optInt("sub_id", -1);
        AgentCommand local = new AgentCommand(commandID, action, callID,
                command.optString("number", ""), command.optString("message", ""), slotId, subId, slotStr);
        AgentCommandDispatcher.Result result = execute(local);
        JSONObject output = new JSONObject().put("command_id", commandID)
                .put("status", result.success() ? "completed" : "failed");
        if (result.success()) {
            JSONObject detail = new JSONObject();
            if ("send_sms".equals(action)) detail.put("sent", true).put("segments", result.segments());
            else if ("dial".equals(action)) detail.put("dialing", true).put("android_confirmed", true);
            else if ("answer".equals(action)) detail.put("answered", true).put("android_confirmed", true);
            else if ("end".equals(action) || "reject".equals(action)) detail.put("ended", true).put("android_confirmed", true);
            else detail.put("sent", true);
            output.put("result", detail);
        } else {
            output.put("error", result.error());
        }
        return rememberCommand(commandKey, output);
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
        return command(action, callID, number, message, -1, -1, "");
    }

    private AgentClient.ForwardResponse command(String action, String callID, String number, String message,
                                                int slotId, int subId, String slot)
            throws Exception {
        AgentCommandDispatcher.Result result = execute(new AgentCommand(
                UUID.randomUUID().toString(), action, callID, number, message, slotId, subId, slot));
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
            String targetId = input.optString("call_id",
                    input.optString("call_uuid", input.optString("callUUID", "")));
            // 客户端在拨号时自造的 call_uuid 先映射回权威的 android 通话 ID
            targetId = resolveClientCallID(targetId);
            return CallRepository.idForPublishedAction(action, targetId,
                    activeCall == null ? "" : activeCall.optString("id"),
                    activeCall == null ? "" : activeCall.optString("android_id"));
        }
    }

    /** 客户端自造 call_uuid → 权威 android 通话 ID 的有界映射表。 */
    private static final int MAX_CLIENT_CALL_IDS = 32;
    private final java.util.Map<String, String> clientCallIDs = new java.util.LinkedHashMap<>();

    private void rememberClientCallID(String clientID, String androidID) {
        if (clientID == null || clientID.isEmpty() || androidID == null || androidID.isEmpty()) return;
        synchronized (clientCallIDs) {
            clientCallIDs.put(clientID, androidID);
            while (clientCallIDs.size() > MAX_CLIENT_CALL_IDS) {
                clientCallIDs.remove(clientCallIDs.keySet().iterator().next());
            }
        }
    }

    private String resolveClientCallID(String requestedID) {
        if (requestedID == null || requestedID.isEmpty()) return "";
        synchronized (clientCallIDs) {
            return clientCallIDs.getOrDefault(requestedID, requestedID);
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

    private void publishClusterEvent(JSONObject event) {
        synchronized (clusterEventsList) {
            long rev = clusterEvents.advance();
            try {
                event.put("revision", rev);
            } catch (Exception ignored) {}
            clusterEventsList.add(event);
            while (clusterEventsList.size() > MAX_CLUSTER_EVENTS) {
                clusterEventsList.remove(0);
            }
        }
    }

    private JSONArray getClusterEventsAfter(long after) {
        JSONArray array = new JSONArray();
        synchronized (clusterEventsList) {
            for (JSONObject ev : clusterEventsList) {
                if (ev.optLong("revision", 0L) > after) {
                    array.put(ev);
                }
            }
        }
        return array;
    }

    private void applyCallEvent(JSONObject event) throws Exception {
        String callUuid = "";
        String number = "未知号码";
        int slotId = 0;
        String state = event.optString("state", "");
        boolean isEnded = "ended".equals(state);
        boolean isRinging = "incoming".equals(state) || "alerting".equals(state) || "ringing".equals(state);

        synchronized (callsLock) {
            if (isEnded) {
                if (activeCall != null) {
                    callUuid = activeCall.optString("id", activeCall.optString("android_id", ""));
                    activeCall.put("state", "ended").put("ended_at", Instant.now().toString())
                            .put("updated_at", Instant.now().toString());
                    callHistory.put(activeCall);
                    activeCall = null;
                }
            } else {
                if (activeCall == null || !event.optString("call_id").equals(activeCall.optString("android_id"))) {
                    activeCall = new JSONObject().put("id", event.optString("call_id"))
                            .put("android_id", event.optString("call_id")).put("index", 1)
                            .put("started_at", Instant.now().toString()).put("missed", false);
                }
                activeCall.put("direction", event.optString("direction"))
                        .put("state", state).put("number", event.optString("number"))
                        .put("updated_at", Instant.now().toString());
                if (event.has("slot_id")) activeCall.put("slot_id", event.optInt("slot_id"));
                if (event.has("sub_id")) activeCall.put("sub_id", event.optInt("sub_id"));
                if (event.has("carrier")) activeCall.put("carrier", event.optString("carrier"));
                if (event.has("target_number")) activeCall.put("target_number", event.optString("target_number"));

                callUuid = activeCall.optString("id", activeCall.optString("android_id", ""));
                number = activeCall.optString("number", "未知号码");
                slotId = activeCall.optInt("slot_id", 0);
            }
        }

        if (isEnded && !callUuid.isEmpty()) {
            JSONObject dismiss = new JSONObject()
                    .put("type", "ring_group_dismiss")
                    .put("call_uuid", callUuid)
                    .put("reason", "ended");
            publishClusterEvent(dismiss);
        } else if (isRinging && !callUuid.isEmpty()) {
            JSONObject broadcast = new JSONObject()
                    .put("type", "ring_group_broadcast")
                    .put("call_uuid", callUuid)
                    .put("caller_number", number)
                    .put("slot_index", slotId);
            publishClusterEvent(broadcast);
        } else if (!callUuid.isEmpty()) {
            // 通话状态演进（dialing/active/held 等）向集群广播：macOS 依据该事件
            // 把外呼切换为"通话中"，或在他处接听时自动收起振铃横幅。
            JSONObject stateEvent = new JSONObject()
                    .put("type", "call_state")
                    .put("call_uuid", callUuid)
                    .put("state", state)
                    .put("direction", event.optString("direction"))
                    .put("number", number);
            publishClusterEvent(stateEvent);
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
                .put("call", callSnapshot())
                .put("slots", SIMSlotManager.getSlotsJSON(context))
                .put("active_slots_count", SIMSlotManager.getActiveSlots(context).size())
                .toString());
    }

    private AgentClient.ForwardResponse waitForClusterEvents(String pathAndQuery) throws Exception {
        StandaloneLongPoll.Request request = StandaloneLongPoll.parse(pathAndQuery, 15_000);
        long after = request.after();

        // 1. Check for events after cursor
        JSONArray pending = getClusterEventsAfter(after);
        if (pending.length() > 0) {
            return ok(pending.toString());
        }

        // 2. If client has cursor 0, check for active call or return initial sync
        if (after == 0) {
            synchronized (callsLock) {
                if (activeCall != null) {
                    String state = activeCall.optString("state", "");
                    if ("incoming".equals(state) || "alerting".equals(state) || "ringing".equals(state)) {
                        JSONObject b = new JSONObject()
                                .put("type", "ring_group_broadcast")
                                .put("call_uuid", activeCall.optString("id", activeCall.optString("android_id", "")))
                                .put("caller_number", activeCall.optString("number", "未知号码"))
                                .put("slot_index", activeCall.optInt("slot_id", 0));
                        publishClusterEvent(b);
                        return ok(getClusterEventsAfter(after).toString());
                    }
                }
            }
            // Client is fresh (after=0) and there are no active calls or pending events.
            // Return an initial sync event so client knows the current revision cursor and stops polling after=0.
            JSONObject sync = new JSONObject()
                    .put("type", "sync")
                    .put("revision", clusterEvents.revision());
            JSONArray syncArray = new JSONArray();
            syncArray.put(sync);
            return ok(syncArray.toString());
        }

        // 3. Client cursor is after > 0. Wait for new events.
        long deadline = System.currentTimeMillis() + request.timeoutMillis();
        while (System.currentTimeMillis() < deadline) {
            long remaining = deadline - System.currentTimeMillis();
            if (remaining <= 0) break;
            clusterEvents.awaitChange(after, (int) Math.min(remaining, 15_000L));
            pending = getClusterEventsAfter(after);
            if (pending.length() > 0) {
                return ok(pending.toString());
            }
            if (clusterEvents.revision() != after) {
                // Revision changed but no cluster events were recorded (e.g. internal change)
                // Return a sync event so client updates cursor and avoids tight loop
                JSONObject sync = new JSONObject()
                        .put("type", "sync")
                        .put("revision", clusterEvents.revision());
                JSONArray syncArray = new JSONArray();
                syncArray.put(sync);
                return ok(syncArray.toString());
            }
        }
        return ok("[]");
    }

    private JSONArray v2Sims() {
        JSONArray array = new JSONArray();
        java.util.List<SIMSlotInfo> slots = SIMSlotManager.getActiveSlots(context);
        if (slots.isEmpty()) {
            try {
                JSONObject fallback = new JSONObject()
                        .put("slot_index", 0)
                        .put("slot_id", 0)
                        .put("carrier_name", "蜂窝网络")
                        .put("phone_number", AndroidAgentIdentity.phoneNumber(context))
                        .put("signal_bars", 5)
                        .put("cellular_state", "registered")
                        .put("vowifi_active", false)
                        .put("battery_level", 95)
                        .put("is_charging", true)
                        .put("is_default_voice", true)
                        .put("is_default_data", true);
                array.put(fallback);
            } catch (Exception ignored) {}
        } else {
            for (SIMSlotInfo slot : slots) {
                try {
                    String cName = slot.carrierName();
                    if (cName == null || cName.isBlank()) cName = slot.displayName();
                    if (cName == null || cName.isBlank()) cName = "蜂窝卡槽 " + (slot.slotIndex() + 1);
                    JSONObject obj = new JSONObject()
                            .put("slot_index", slot.slotIndex())
                            .put("slot_id", slot.slotIndex())
                            .put("sub_id", slot.subscriptionId())
                            .put("carrier_name", cName)
                            .put("phone_number", slot.number() != null ? slot.number() : "")
                            .put("signal_bars", 5)
                            .put("cellular_state", "ready".equalsIgnoreCase(slot.simState()) || "LOADED".equalsIgnoreCase(slot.simState()) ? "registered" : "searching")
                            .put("vowifi_active", false)
                            .put("battery_level", 95)
                            .put("is_charging", true)
                            .put("is_default_voice", slot.isDefaultVoice())
                            .put("is_default_data", true)
                            .put("is_default_sms", slot.isDefaultSms());
                    array.put(obj);
                } catch (Exception ignored) {}
            }
        }
        return array;
    }

    private JSONArray v2Sms() throws Exception {
        JSONArray original = smsStore.localMessages();
        JSONArray v2Array = new JSONArray();
        for (int i = 0; i < original.length(); i++) {
            JSONObject msg = original.getJSONObject(i);
            JSONObject item = new JSONObject();
            item.put("delivery_id", msg.optString("delivery_id"));
            item.put("sender", msg.optString("sender"));
            item.put("content", msg.optString("content"));
            item.put("slot_index", msg.optInt("slot_id", 0));
            item.put("direction", "incoming");
            item.put("timestamp", msg.optString("timestamp"));
            String code = extractVerificationCode(msg.optString("content"));
            if (code != null) item.put("code", code);
            v2Array.put(item);
        }
        return v2Array;
    }

    private static String extractVerificationCode(String content) {
        if (content == null || content.isEmpty()) return null;
        java.util.regex.Matcher m = java.util.regex.Pattern.compile("(?<!\\d)(\\d{4,8})(?!\\d)").matcher(content);
        return m.find() ? m.group(1) : null;
    }

    private static AgentClient.ForwardResponse ok(String body) { return new AgentClient.ForwardResponse(200, body); }
    private static AgentClient.ForwardResponse error(int status, String message) throws Exception {
        return new AgentClient.ForwardResponse(status, new JSONObject().put("error", message).toString());
    }
}
