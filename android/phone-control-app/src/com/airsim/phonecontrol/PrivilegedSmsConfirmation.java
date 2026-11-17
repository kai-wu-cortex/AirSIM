package com.airsim.phonecontrol;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import java.util.ArrayList;
import java.util.UUID;

/** App-owned sent callbacks survive an exception in the privileged sender after dispatch. */
final class PrivilegedSmsConfirmation {
    interface Dispatch { String send(ArrayList<PendingIntent> callbacks) throws Exception; }

    static String send(Context context, String destination, String body, int subscription, Dispatch dispatch) {
        final int count;
        try {
            var manager = SMSCommandExecutor.managerForSubscription(context, subscription);
            if (manager == null) return "error:no_service";
            var parts = manager.divideMessage(body);
            if (parts == null || parts.isEmpty()) return "error:divide";
            count = parts.size();
        } catch (RuntimeException error) { return "error:prepare:" + error.getClass().getSimpleName(); }
        String id = UUID.randomUUID().toString();
        String trace = id.substring(0, 8);
        String action = context.getPackageName() + ".PRIVILEGED_SMS_SENT." + id;
        SMSConfirmation confirmation = new SMSConfirmation(count);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context ignored, Intent intent) {
                if (!action.equals(intent.getAction())) return;
                int segment = intent.getIntExtra("segment", -1);
                confirmation.record(segment, getResultCode());
                BridgeLog.info("sms_privileged_callback trace=" + trace + " segment=" + segment
                        + " result=" + getResultCode());
            }
        };
        ArrayList<PendingIntent> callbacks = new ArrayList<>(count);
        boolean registered = false;
        boolean dispatched = false;
        try {
            if (Build.VERSION.SDK_INT >= 33)
                context.registerReceiver(receiver, new IntentFilter(action), Context.RECEIVER_NOT_EXPORTED);
            else context.registerReceiver(receiver, new IntentFilter(action));
            registered = true;
            for (int index = 0; index < count; index++) {
                Intent intent = new Intent(action).setPackage(context.getPackageName()).putExtra("segment", index);
                callbacks.add(PendingIntent.getBroadcast(context, index, intent,
                        PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_IMMUTABLE));
            }
            dispatched = true;
            String result;
            try { result = dispatch.send(callbacks); }
            catch (Exception error) { result = "error:send_unknown:" + error.getClass().getSimpleName(); }
            // Only pre-dispatch failures may select a different sender. Otherwise the
            // actual system callback wins over an AppOps/Binder exception or API return.
            if (SMSPrivilegedResult.mayFallback(result)) return result;
            BridgeLog.info("sms_privileged_wait trace=" + trace + " segments=" + count
                    + " dispatch=" + result);
            SMSConfirmation.Outcome outcome = confirmation.await(45_000L);
            String resolved = SMSPrivilegedResult.confirmed(outcome, count);
            BridgeLog.info("sms_privileged_resolved trace=" + trace + " result=" + resolved
                    + " callbacks=" + outcome.confirmedSegments());
            return resolved;
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            return "error:send_unknown:interrupted";
        } catch (RuntimeException error) {
            return "error:" + (dispatched ? "send_unknown:" : "prepare:") + error.getClass().getSimpleName();
        } finally {
            for (PendingIntent callback : callbacks) callback.cancel();
            if (registered) context.unregisterReceiver(receiver);
        }
    }
}
