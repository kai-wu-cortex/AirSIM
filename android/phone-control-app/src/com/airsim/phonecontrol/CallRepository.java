package com.airsim.phonecontrol;

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

    private CallRepository() {}

    public static String add(Call call) {
        String id = UUID.randomUUID().toString();
        IDS.put(call, id);
        CALLS.put(id, call);
        return id;
    }

    public static String id(Call call) {
        return IDS.getOrDefault(call, "");
    }

    public static void remove(Call call) {
        String id = IDS.remove(call);
        if (id != null) CALLS.remove(id);
    }

    public static String firstId() {
        for (String id : CALLS.keySet()) return id;
        return "";
    }

    public static void disconnectAll() {
        new Handler(Looper.getMainLooper()).post(() -> {
            for (Call call : CALLS.values()) {
                try { call.disconnect(); }
                catch (RuntimeException ignored) {}
            }
        });
    }

    public static ActionResult execute(AgentCommand command, TelecomManager telecomManager) {
        if (!command.isSupported()) return ActionResult.failure("unsupported action");
        if ("dial".equals(command.action)) {
            if (command.number.isEmpty()) return ActionResult.failure("number missing");
            new Handler(Looper.getMainLooper()).post(() -> telecomManager.placeCall(Uri.parse("tel:" + command.number), null));
            return ActionResult.success();
        }
        Call call = CALLS.get(command.callId);
        if (call == null) return ActionResult.failure("active call id mismatch");
        CountDownLatch invoked = new CountDownLatch(1);
		AtomicReference<Throwable> invocationError = new AtomicReference<>();
        new Handler(Looper.getMainLooper()).post(() -> {
            try {
                switch (command.action) {
                    case "answer" -> call.answer(VideoProfile.STATE_AUDIO_ONLY);
                    case "reject" -> call.reject(false, null);
                    case "end" -> call.disconnect();
                    case "dtmf" -> {
                        if (command.number.length() != 1) throw new IllegalArgumentException("DTMF digit missing");
                        call.playDtmfTone(command.number.charAt(0));
                        call.stopDtmfTone();
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
                if (call.getState() == expected) return ActionResult.success();
                Thread.sleep(50);
            }
            return ActionResult.failure("Telecom state confirmation timeout");
        } catch (Exception error) {
            return ActionResult.failure(error.getClass().getSimpleName() + ": " + error.getMessage());
        }
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
