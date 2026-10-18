package com.airsim.phonecontrol.voble;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.HashSet;

public final class VoBLECallController {
    public interface Gateway {
        Result execute(Request request);
    }

    public record Request(
            String requestId, String action, String callId, String number, long generation) {}

    public record Result(boolean success, String code, String detail) {
        public static Result success(String detail) { return new Result(true, "ok", detail); }
        public static Result failure(String code) { return new Result(false, code, ""); }
        public static Result failure(String code, String detail) { return new Result(false, code, detail); }
    }

    private static final int MAX_CACHED_RESULTS = 256;
    private static final Set<String> ACTIONS = Set.of("dial", "answer", "reject", "end", "dtmf");
    private final Gateway gateway;
    private final LinkedHashMap<String, Result> results = new LinkedHashMap<>();
    private final Set<String> terminalEvents = new HashSet<>();
    private String currentCallId = "";
    private long currentGeneration;

    public VoBLECallController(Gateway gateway) {
        this.gateway = gateway;
    }

    public synchronized Result execute(Request request, boolean authenticated) {
        if (!authenticated) return Result.failure("authentication_failed");
        if (request == null || request.requestId == null || request.requestId.isBlank()
                || request.action == null || !ACTIONS.contains(request.action)) {
            return Result.failure("invalid_request");
        }
        Result cached = results.get(request.requestId);
        if (cached != null) return cached;
        // Telecom may publish the terminal event before the BLE hangup arrives.
        // A known ended identity is already satisfied. Never invoke Telecom or
        // use the current call as a fallback for this delayed request.
        if (("end".equals(request.action) || "reject".equals(request.action))
                && terminalEvents.contains(request.callId + ":" + request.generation)) {
            return remember(request.requestId, Result.success("already_ended"));
        }
        boolean nextDial = "dial".equals(request.action)
                && currentCallId.isEmpty()
                && request.generation > currentGeneration;
        if (request.generation != currentGeneration && !nextDial) return remember(
                request.requestId, Result.failure("stale_generation"));
        if (!"dial".equals(request.action) && !currentCallId.equals(request.callId)) {
            return remember(request.requestId, Result.failure("call_mismatch"));
        }
        Result result;
        try {
            result = gateway.execute(request);
            if (result == null) result = Result.failure("gateway_failed");
        } catch (RuntimeException error) {
            result = Result.failure("gateway_failed", error.getClass().getSimpleName());
        }
        if (nextDial && result.success) {
            // Own the provisional iOS call immediately. The first Telecom event
            // will replace this ID with Android's authoritative call ID while
            // retaining the same generation.
            currentCallId = request.callId;
            currentGeneration = request.generation;
        }
        return remember(request.requestId, result);
    }

    public synchronized Result executeOnce(
            Request request, boolean authenticated, Gateway operation) {
        if (!authenticated) return Result.failure("authentication_failed");
        if (request == null || request.requestId == null || request.requestId.isBlank()
                || operation == null) return Result.failure("invalid_request");
        Result cached = results.get(request.requestId);
        if (cached != null) return cached;
        Result result;
        try {
            result = operation.execute(request);
            if (result == null) result = Result.failure("gateway_failed");
        } catch (RuntimeException error) {
            result = Result.failure("gateway_failed", error.getClass().getSimpleName());
        }
        return remember(request.requestId, result);
    }

    /** Returns true only for the first matching terminal event. */
    public synchronized boolean observeCall(String callId, long generation, String state) {
        if (callId == null || callId.isBlank() || generation <= 0) return false;
        if (!"ended".equals(state)) {
            if (generation >= currentGeneration) {
                currentCallId = callId;
                currentGeneration = generation;
            }
            return false;
        }
        if (!currentCallId.equals(callId) || currentGeneration != generation) return false;
        String key = callId + ":" + generation;
        if (!terminalEvents.add(key)) return false;
        currentCallId = "";
        return true;
    }

    public synchronized long currentGeneration() { return currentGeneration; }

    public synchronized boolean ownsCall(String callId, long generation) {
        return callId != null && callId.equals(currentCallId) && generation == currentGeneration;
    }

    private Result remember(String requestId, Result result) {
        results.put(requestId, result);
        while (results.size() > MAX_CACHED_RESULTS) {
            Map.Entry<String, Result> oldest = results.entrySet().iterator().next();
            results.remove(oldest.getKey());
        }
        return result;
    }
}
