package com.airsim.phonecontrol;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.telecom.TelecomManager;
import android.telecom.VideoProfile;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public final class CallRepository {
    private static final Map<String, Call> CALLS = new ConcurrentHashMap<>();
    private static final Map<Call, String> IDS = new ConcurrentHashMap<>();
    private static final Object OUTGOING_LOCK = new Object();
    private static final java.util.Set<OutgoingCallObservation> OUTGOING =
            java.util.Collections.newSetFromMap(new java.util.WeakHashMap<>());

    private CallRepository() {}

    public static String add(Call call) {
        String id = UUID.randomUUID().toString();
        synchronized (OUTGOING_LOCK) {
            IDS.put(call, id);
            CALLS.put(id, call);
            var iterator = OUTGOING.iterator();
            while (iterator.hasNext()) {
                OutgoingCallObservation observation = iterator.next();
                if (System.nanoTime() >= observation.deadline || observation.created.size() >= 64) {
                    if (observation.created.size() >= 64) observation.overflow = true;
                    iterator.remove();
                } else observation.created.put(id, call);
            }
        }
        return id;
    }

    /** Capture creation identity before placeCall, independently of delayed network events. */
    static OutgoingCallObservation observeOutgoing(String number) {
        synchronized (OUTGOING_LOCK) {
            var observation = new OutgoingCallObservation(number);
            OUTGOING.add(observation);
            return observation;
        }
    }

    static final class OutgoingCallObservation implements AutoCloseable {
        private final String number;
        private final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15);
        private final Map<String, Call> created = new java.util.LinkedHashMap<>();
        private boolean closed;
        private boolean overflow;

        private OutgoingCallObservation(String number) { this.number = number == null ? "" : number; }

        String matchingCallID() {
            synchronized (OUTGOING_LOCK) {
                if (System.nanoTime() >= deadline) OUTGOING.remove(this);
                if (closed || overflow || number.isBlank()) return "";
                String candidate = "";
                for (Map.Entry<String, Call> entry : created.entrySet()) {
                    Call.Details details = entry.getValue().getDetails();
                    if (details == null || details.getCallDirection() != Call.Details.DIRECTION_OUTGOING
                            || details.getHandle() == null || !android.telephony.PhoneNumberUtils.compare(
                            details.getHandle().getSchemeSpecificPart(), number)) continue;
                    if (!candidate.isEmpty()) return "";
                    candidate = entry.getKey();
                }
                return candidate;
            }
        }

        @Override public void close() {
            synchronized (OUTGOING_LOCK) {
                closed = true;
                OUTGOING.remove(this);
                created.clear();
            }
        }
    }

    public static String id(Call call) {
        return IDS.getOrDefault(call, "");
    }

    public static void remove(Call call) {
        String id = IDS.remove(call);
        if (id != null) CALLS.remove(id);
    }

    public static String firstId() {
        return idForAction("end");
    }

    public static java.util.Set<String> callIDs() { return new java.util.HashSet<>(CALLS.keySet()); }

    public static String newOutgoingCallSince(java.util.Set<String> before, String number) {
        if (number == null || number.trim().isEmpty()) return "";
        String candidate = "";
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            int state = entry.getValue().getState();
            if (before.contains(entry.getKey()) || state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING) continue;
            Call.Details details = entry.getValue().getDetails();
            if (details == null || details.getCallDirection() != Call.Details.DIRECTION_OUTGOING
                    || details.getHandle() == null || !android.telephony.PhoneNumberUtils.compare(
                            details.getHandle().getSchemeSpecificPart(), number)) continue;
            if (!candidate.isEmpty()) return "";
            candidate = entry.getKey();
        }
        return candidate;
    }

    public static void disconnect(String callID) {
        Call owned = CALLS.get(callID);
        if (owned == null) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            if (CALLS.get(callID) != owned || owned.getState() == Call.STATE_DISCONNECTED
                    || owned.getState() == Call.STATE_DISCONNECTING) return;
            try { owned.disconnect(); } catch (RuntimeException ignored) {}
        });
    }

    public static int state(String callId) {
        Call call = CALLS.get(callId);
        return call == null ? -1 : call.getState();
    }

    /** Privacy-safe Telecom state for feedback diagnostics; never includes numbers or IDs. */
    public static String diagnosticState() {
        for (Call call : CALLS.values()) {
            if (call.getState() == Call.STATE_ACTIVE) return "active";
            if (call.getState() == Call.STATE_RINGING) return "ringing";
            if (call.getState() == Call.STATE_DIALING) return "dialing";
            if (call.getState() == Call.STATE_HOLDING) return "holding";
        }
        return CALLS.isEmpty() ? "idle" : "disconnecting";
    }

    public static String number(String callId) {
        Call call = CALLS.get(callId);
        if (call == null || call.getDetails() == null || call.getDetails().getHandle() == null) return "";
        String value = call.getDetails().getHandle().getSchemeSpecificPart();
        return value == null ? "" : value;
    }

    public static String idForAction(String action) {
        int preferred = ("answer".equals(action) || "reject".equals(action))
                ? Call.STATE_RINGING : Call.STATE_ACTIVE;
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            if (entry.getValue().getState() == preferred) return entry.getKey();
        }
        if ("answer".equals(action)) return "";
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            int state = entry.getValue().getState();
            if (state != Call.STATE_DISCONNECTED && state != Call.STATE_DISCONNECTING) return entry.getKey();
        }
        return "";
    }

    static String idForPublishedAction(String action, String requestedID,
                                       String publishedID, String androidID) {
        if (requestedID == null || requestedID.isBlank()) return idForAction(action);
        if (!requestedID.equals(publishedID)) return "";
        Call call = CALLS.get(androidID);
        if (call == null) return "";
        int state = call.getState();
        if (state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING
                || ("answer".equals(action) && state != Call.STATE_RINGING)) return "";
        return androidID;
    }

    public static void disconnectAll() {
        new Handler(Looper.getMainLooper()).post(() -> {
            for (Call call : CALLS.values()) {
                try { call.disconnect(); }
                catch (RuntimeException ignored) {}
            }
        });
    }

    public static ActionResult execute(Context context, AgentCommand command) {
        if (!command.isSupported()) return ActionResult.failure("unsupported action");
        if ("dial".equals(command.action)) {
            if (command.number.isEmpty()) return ActionResult.failure("number missing");
            String error = TelecomInvocation.run(
                    task -> new Handler(Looper.getMainLooper()).post(task),
                    () -> context.getSystemService(TelecomManager.class).placeCall(
                            Uri.parse("tel:" + command.number), DefaultCallAccount.dialExtras(context, command.simAccount)),
                    2_000L);
            return error.isEmpty() ? ActionResult.success() : ActionResult.failure(error);
        }
        Call call = CALLS.get(command.callId);
        if (call == null) return ActionResult.failure("active call id mismatch");
        CountDownLatch invoked = new CountDownLatch(1);
		AtomicReference<Throwable> invocationError = new AtomicReference<>();
        new Handler(Looper.getMainLooper()).post(() -> {
            try {
                switch (command.action) {
                    case "answer" -> call.answer(VideoProfile.STATE_AUDIO_ONLY);
                    case "reject" -> {
                        if (call.getState() == Call.STATE_RINGING) call.reject(false, null);
                        else call.disconnect();
                    }
                    case "end" -> call.disconnect();
                    case "dtmf" -> {
                        if (command.number.length() != 1) throw new IllegalArgumentException("DTMF digit missing");
                        call.playDtmfTone(command.number.charAt(0));
                        // Some ColorOS/Telecom stacks cancel a DTMF tone when
                        // stopDtmfTone() is called in the same main-thread turn.
                        // Let the tone reach the network before stopping it.
                        new Handler(Looper.getMainLooper()).postDelayed(() -> {
                            try { call.stopDtmfTone(); } catch (RuntimeException ignored) {}
                        }, 180);
                    }
                    default -> throw new IllegalArgumentException("unsupported action");
                }
			} catch (Throwable error) {
				invocationError.set(error);
            } finally {
                invoked.countDown();
            }
        });
        try {
            if (!invoked.await(2, TimeUnit.SECONDS)) return ActionResult.failure("Telecom invocation timeout");
			if (invocationError.get() != null) {
				Throwable error = invocationError.get();
				return ActionResult.failure(error.getClass().getSimpleName() + ": " + error.getMessage());
			}
            if ("dtmf".equals(command.action)) return ActionResult.success();
            int expected = "answer".equals(command.action) ? Call.STATE_ACTIVE : Call.STATE_DISCONNECTED;
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (System.nanoTime() < deadline) {
                if (call.getState() == expected || (expected == Call.STATE_DISCONNECTED && !IDS.containsKey(call))) {
                    return ActionResult.success();
                }
                Thread.sleep(50);
            }
            // A few OEM Telecom implementations accept Call.disconnect() but
            // never deliver the terminal callback. Ask Telecom to end the same
            // call once before reporting failure; never reboot/restart audio.
            if ("end".equals(command.action) && !IDS.containsKey(call)) return ActionResult.success();
            if ("end".equals(command.action)) {
                try {
                    TelecomManager telecom = context.getSystemService(TelecomManager.class);
                    if (telecom != null) {
                        java.lang.reflect.Method endCall =
                                TelecomManager.class.getMethod("endCall");
                        endCall.invoke(telecom);
                    }
                } catch (Exception ignored) {}
                long fallbackDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                while (System.nanoTime() < fallbackDeadline) {
                    if (!IDS.containsKey(call) || call.getState() == Call.STATE_DISCONNECTED) {
                        return ActionResult.success();
                    }
                    Thread.sleep(50);
                }
            }
            return ActionResult.failure("Telecom state confirmation timeout");
        } catch (Exception error) {
            return ActionResult.failure(error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    public static ActionResult executeRemote(
            Context context, String requestId, String action, String callId, String number) {
        return executeRemote(context, requestId, action, callId, number, "");
    }

    public static ActionResult executeRemote(
            Context context, String requestId, String action, String callId, String number,
            String simAccount) {
        return execute(context, new AgentCommand(requestId, action, callId, number, "", simAccount));
    }

    public static final class ActionResult {
        public final boolean success;
        public final String error;

        ActionResult(boolean success, String error) {
            this.success = success;
            this.error = error;
        }

        static ActionResult success() { return new ActionResult(true, ""); }
        static ActionResult failure(String error) { return new ActionResult(false, error == null ? "unknown" : error); }
    }
}
