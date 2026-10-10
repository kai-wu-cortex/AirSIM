package com.airsim.phonecontrol;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

import org.json.JSONObject;

import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Receives carrier SMS without requiring the default-SMS-app role. */
public final class IncomingSMSReceiver extends BroadcastReceiver {
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    @Override public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        PendingResult pending = goAsync();
        Context application = context.getApplicationContext();
        WORKER.execute(() -> {
            try {
                SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
                if (parts == null || parts.length == 0) return;
                StringBuilder content = new StringBuilder();
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                String sender = parts[0].getOriginatingAddress();
                long timestamp = parts[0].getTimestampMillis();
                for (SmsMessage part : parts) {
                    if (part == null) continue;
                    content.append(part.getMessageBody() == null ? "" : part.getMessageBody());
                    byte[] pdu = part.getPdu();
                    if (pdu != null) digest.update(pdu);
                }
                if (content.length() == 0) return;
                digest.update((sender == null ? "" : sender).getBytes(StandardCharsets.UTF_8));
                digest.update(Long.toString(timestamp).getBytes(StandardCharsets.US_ASCII));
                digest.update(content.toString().getBytes(StandardCharsets.UTF_8));
                StringBuilder id = new StringBuilder("android-sms-");
                for (byte value : digest.digest()) id.append(String.format("%02x", value & 0xff));
                JSONObject event = new JSONObject(WireJson.smsEvent(UUID.randomUUID().toString(),
                        id.toString(), sender == null ? "" : sender, content.toString(),
                        Instant.ofEpochMilli(timestamp > 0 ? timestamp : System.currentTimeMillis()).toString()));
                if (RuntimeMode.isStandalone(application)) {
                    StandaloneAgentGateway.get(application).sendSMSEvent(event.toString());
                } else {
                    new StandaloneSMSStore(application).add(event, true);
                    AgentWatchdogService.start(application);
                }
                BridgeLog.info("incoming_sms_queued delivery_id=" + DebugRedactor.safeIdentifier(id.toString()));
            } catch (Exception error) {
                BridgeLog.error("incoming_sms_queue_failed", error);
            } finally {
                pending.finish();
            }
        });
    }
}
