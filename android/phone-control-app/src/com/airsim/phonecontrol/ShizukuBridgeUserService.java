package com.airsim.phonecontrol;

import android.content.Context;
import android.media.AudioManager;
import android.net.Uri;
import android.provider.BaseColumns;
import android.provider.Telephony;
import android.os.Binder;
import android.os.Build;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.telephony.SmsManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

import org.json.JSONArray;
import org.json.JSONObject;

public final class ShizukuBridgeUserService extends Binder {
    private static final String TAG = "AirSIMShizuku";
    private static final int DESTROY_TRANSACTION = 16777115;
    private static final int DESTROY_TRANSACTION_AIDL = 16777114;

    private final Object lock = new Object();
    private final Object audioLock = new Object();
    private final BoundedAudioOperation audioOperations = new BoundedAudioOperation(250);
    private String sourceApk = "";
    private String packageName = "";
    private boolean standalonePCM;
    private java.lang.Process bridgeProcess;
    private boolean bridgeDesired;
    private volatile boolean shuttingDown;
    private android.net.LocalServerSocket bridgeOwnership;
    private Context serviceContext;
    private volatile LocalOutputMuteController outputMute;
    private volatile LocalAudioIsolationController localIsolation;
    private LocalAudioIsolationController.Store isolationStore;
    private final IsolationLease isolationLease = new IsolationLease();
    private java.util.function.LongSupplier isolationClock = () -> System.nanoTime() / 1_000_000L;
    private final java.util.concurrent.ScheduledExecutorService audioRecovery =
            java.util.concurrent.Executors.newSingleThreadScheduledExecutor(task -> {
                Thread thread = new Thread(task, "AirSIM-isolation-recovery"); thread.setDaemon(true); return thread;
            });
    private java.util.concurrent.ScheduledFuture<?> recoveryTask;
    private int recoveryFailures;
    private long nextRecoveryMillis;
    private final java.util.concurrent.CountDownLatch shutdownComplete = new java.util.concurrent.CountDownLatch(1);
    private volatile String outputStrategy = "vowlan";
    private volatile CallOutputPolicyMute callOutputPolicyMute;
    private final PCMHealthEvidence pcmEvidence = new PCMHealthEvidence();

    public ShizukuBridgeUserService() {
        Log.i(TAG, "created without context uid=" + Process.myUid());
    }

    public ShizukuBridgeUserService(Context context) {
        serviceContext = context;
        sourceApk = context.getApplicationInfo().sourceDir;
        packageName = context.getPackageName();
        standalonePCM = RuntimeMode.isStandalone(context);
        Log.i(TAG, "created uid=" + Process.myUid());
    }

    @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
            throws RemoteException {
        if (code == IBinder.INTERFACE_TRANSACTION) {
            reply.writeString(PrivilegedBridgeProtocol.DESCRIPTOR);
            return true;
        }
        if (code == DESTROY_TRANSACTION || code == DESTROY_TRANSACTION_AIDL) {
            destroy();
            return true;
        }
        data.enforceInterface(PrivilegedBridgeProtocol.DESCRIPTOR);
        try {
            String result = switch (code) {
                case PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE -> ensureBridgeStarted();
                case PrivilegedBridgeProtocol.TRANSACTION_STATUS -> status();
                case PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED -> {
                    boolean target = data.readInt() != 0;
                    // New clients append the transport; older clients read as VoWLAN.
                    yield setLocalOutputMuted(target,
                            data.dataAvail() > 0 ? data.readString() : "vowlan");
                }
                case PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_POLICY ->
                        setLocalOutputMuted(data.readInt() != 0, data.readString(), data.readString());
                case PrivilegedBridgeProtocol.TRANSACTION_RENEW_ISOLATION_LEASE -> renewIsolationLease();
                case PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE -> ensureDialerRole();
                case PrivilegedBridgeProtocol.TRANSACTION_AUDIO_SNAPSHOT -> audioSnapshot();
                case PrivilegedBridgeProtocol.TRANSACTION_SEND_SMS ->
                        sendSms(data.readString(), data.readString(), data.readInt());
                case PrivilegedBridgeProtocol.TRANSACTION_SEND_SMS_CONFIRMED ->
                        sendSms(data.readString(), data.readString(), data.readInt(),
                                data.createTypedArrayList(android.app.PendingIntent.CREATOR));
                case PrivilegedBridgeProtocol.TRANSACTION_SMS_PREFLIGHT -> smsPreflight();
                case PrivilegedBridgeProtocol.TRANSACTION_RESOLVE_SMS_SUBSCRIPTION ->
                        resolveSmsSubscription(data.readString());
                case PrivilegedBridgeProtocol.TRANSACTION_RECENT_SMS ->
                        recentSms(data.readLong(), data.readLong(), data.readInt());
                default -> null;
            };
            if (result == null) return super.onTransact(code, data, reply, flags);
            reply.writeNoException();
            reply.writeString(result);
            return true;
        } catch (Throwable error) {
            Log.e(TAG, "transaction failed code=" + code, error);
            reply.writeException(new IllegalStateException(safeMessage(error)));
            return true;
        }
    }

    /** Synthetic text division only; never calls a send API. */
    private String smsPreflight() {
        long identity = Binder.clearCallingIdentity();
        String stage = "manager";
        try {
            SmsManager manager = smsManagerForSubscription(-1);
            if (manager == null) return "error:no_service";
            stage = "divide";
            var parts = manager.divideMessage("AirSIM preflight");
            return "ready:parts=" + (parts == null ? 0 : parts.size()) + " appops_attribution=true";
        } catch (Exception error) {
            StringBuilder result = new StringBuilder("error:" + stage + ":" + error.getClass().getSimpleName());
            for (int i = 0; i < Math.min(5, error.getStackTrace().length); i++) {
                var frame = error.getStackTrace()[i];
                result.append(" at ").append(frame.getClassName()).append('.').append(frame.getMethodName());
            }
            return result.toString();
        } finally { Binder.restoreCallingIdentity(identity); }
    }

    private String sendSms(String destination, String body, int subscriptionId) {
        return sendSms(destination, body, subscriptionId, null);
    }

    private String sendSms(String destination, String body, int subscriptionId,
            ArrayList<android.app.PendingIntent> sentIntents) {
        if (serviceContext == null) return "error:no_context";
        if (destination == null || destination.trim().isEmpty()
                || body == null || body.trim().isEmpty()) return "error:invalid";
        long identity = Binder.clearCallingIdentity();
        String stage = "manager";
        try {
            SmsManager manager = smsManagerForSubscription(subscriptionId);
            if (manager == null) return "error:no_service";
            stage = "divide";
            ArrayList<String> parts = manager.divideMessage(body);
            if (parts == null || parts.isEmpty()) return "error:divide";
            if (sentIntents != null && (sentIntents.size() != parts.size()
                    || sentIntents.contains(null))) return "error:prepare:callback_count";
            stage = "send";
            if (parts.size() == 1) {
                manager.sendTextMessage(destination, null, parts.get(0),
                        sentIntents == null ? null : sentIntents.get(0), null);
            } else {
                manager.sendMultipartTextMessage(destination, null, parts, sentIntents, null);
            }
            Log.i(TAG, "shizuku_sms_accepted segments=" + parts.size());
            return "ok:" + parts.size();
        } catch (SecurityException error) {
            Log.w(TAG, "shizuku_sms_permission_denied");
            return "error:" + ("send".equals(stage) ? "send_unknown:" : "prepare:") + "SecurityException";
        } catch (Exception error) {
            StringBuilder frames = new StringBuilder();
            for (int i = 0; i < Math.min(6, error.getStackTrace().length); i++) {
                var frame = error.getStackTrace()[i];
                frames.append(" at ").append(frame.getClassName()).append('.').append(frame.getMethodName());
            }
            Log.w(TAG, "shizuku_sms_failed stage=" + stage + " type=" + error.getClass().getSimpleName() + frames);
            return "error:" + ("send".equals(stage) ? "send_unknown:" : "prepare:") + error.getClass().getSimpleName();
        } finally {
            Binder.restoreCallingIdentity(identity);
        }
    }

    private SmsManager smsManagerForSubscription(int subscriptionId) throws Exception {
        return PrivilegedSmsRuntime.manager(serviceContext, subscriptionId);
    }

    private String resolveSmsSubscription(String key) {
        if (serviceContext == null || key == null || key.isEmpty() || key.length() > 8192) return "-1";
        long identity = Binder.clearCallingIdentity();
        try {
            // Initialize the telephony registry and obtain a correctly attributed
            // shell context, just as the existing authorized SMS sender does.
            smsManagerForSubscription(-1);
            Context context = serviceContext;
            if (Process.myUid() == 2000) {
                Class<?> activityThread = Class.forName("android.app.ActivityThread");
                Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
                Context system = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
                context = system.createPackageContext("com.android.shell", 0);
            }
            int subscription = DefaultCallAccount.smsSubscription(DefaultCallAccount.snapshot(context), key);
            var subscriptions = context.getSystemService(android.telephony.SubscriptionManager.class);
            if (subscriptions == null || subscriptions.getActiveSubscriptionInfo(subscription) == null) return "-1";
            return Integer.toString(subscription);
        } catch (Exception error) { return "-1"; }
        finally { Binder.restoreCallingIdentity(identity); }
    }

    private String recentSms(long afterId, long cutoffMillis, int limit) {
        if (serviceContext == null) return "error:no_context";
        int boundedLimit = Math.max(1, Math.min(200, limit));
        try {
            String[] projection = {BaseColumns._ID, Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.DATE_SENT, "sub_id"};
            String selection;
            String[] args;
            if (afterId >= 0) {
                selection = BaseColumns._ID + " > ?";
                args = new String[]{Long.toString(afterId)};
            } else {
                selection = Telephony.Sms.DATE + " >= ?";
                args = new String[]{Long.toString(cutoffMillis)};
            }
            Uri uri = Telephony.Sms.Inbox.CONTENT_URI.buildUpon()
                    .appendQueryParameter("limit", Integer.toString(boundedLimit)).build();
            // A ContentResolver is rejected in this app_process; read the way `content` does.
            return ShellProviderQuery.query(uri.getAuthority(), uri, projection, selection, args,
                    BaseColumns._ID + " ASC", cursor -> {
                if (cursor == null) return "error:provider";
                JSONArray rows = new JSONArray();
                while (cursor.moveToNext() && rows.length() < boundedLimit) {
                    rows.put(new JSONObject()
                            .put("id", cursor.getLong(0))
                            .put("address", cursor.getString(1) == null ? "" : cursor.getString(1))
                            .put("body", cursor.getString(2) == null ? "" : cursor.getString(2))
                            .put("date", cursor.getLong(3))
                            .put("date_sent", cursor.getLong(4))
                            .put("sub_id", cursor.getInt(5)));
                }
                return rows.toString();
            });
        } catch (Exception error) {
            Log.w(TAG, "shizuku_sms_inbox_failed type=" + error.getClass().getSimpleName());
            return "error:" + error.getClass().getSimpleName();
        }
    }

    private synchronized String ensureBridgeStarted() throws IOException {
        synchronized (lock) {
            verifyIdentity();
            if (shuttingDown) throw new IOException("privileged service is stopping");
            bridgeDesired = true;
            if (bridgeProcess != null && bridgeProcess.isAlive()) return statusLocked();
            if (sourceApk.isEmpty()) throw new IOException("application source path unavailable");
            // AVF mode must not spawn a bridge that can only exit and restart
            // forever when the AVF tap has not been created yet. Standalone uses
            // loopback and does not require this interface.
            if (!standalonePCM && NetworkInterface.getByName("avf_tap_fixed") == null) {
                throw new IOException("AVF interface unavailable: avf_tap_fixed");
            }
            // A supervisor must own the bridge before it can retire any PCM
            // process. Root and Shizuku must never kill each other's live child.
            if (bridgeOwnership == null) {
                bridgeOwnership = new android.net.LocalServerSocket("airsim-pcm-owner-" + packageName);
            }
        }
        // Recovery belongs to the exclusive PCM owner. A second supervisor must
        // never restore a journal belonging to the first supervisor's live call.
        // Do not hold lock while acquiring audioLock (shutdown takes them in reverse).
        try { recoverInterruptedIsolation(); }
        catch (Exception error) { throw new IOException("上次本机音频隔离尚未恢复，请稍后重试", error); }
        synchronized (lock) {
            stopStaleAudioBridges();
            List<String> command = new ArrayList<>();
            command.add("/system/bin/app_process");
            command.add("/system/bin");
            command.add("com.airsim.bridge.PhoneAudioBridge");
            command.add(standalonePCM ? "--listen-host" : "--listen-interface");
            command.add(standalonePCM ? "127.0.0.1" : "avf_tap_fixed");
            command.add("--listen-port");
            command.add("7580");
            ProcessBuilder builder = new ProcessBuilder(command).redirectErrorStream(true);
            builder.environment().put("CLASSPATH", sourceApk);
            bridgeProcess = builder.start();
            pcmEvidence.reset();
            java.lang.Process launched = bridgeProcess;
            Thread monitor = new Thread(() -> monitorBridge(launched), "airsim-shizuku-pcm-monitor");
            monitor.setDaemon(true);
            monitor.start();
            Log.i(TAG, "PCM bridge process started");
            return statusLocked();
        }
    }

    private void stopStaleAudioBridges() throws IOException {
        List<Integer> stalePids = findStaleAudioBridgePids();
        for (int pid : stalePids) {
            Log.w(TAG, "stopping stale PCM bridge pid=" + pid);
            Process.killProcess(pid);
        }
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (!stalePids.isEmpty() && System.nanoTime() < deadline) {
            stalePids.removeIf(pid -> !new File("/proc/" + pid).exists());
            if (!stalePids.isEmpty()) {
                try { Thread.sleep(50); }
                catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    throw new IOException("interrupted while stopping stale PCM bridge", interrupted);
                }
            }
        }
        if (!stalePids.isEmpty()) {
            throw new IOException("stale PCM bridge did not exit pid=" + stalePids.get(0));
        }
    }

    private List<Integer> findStaleAudioBridgePids() {
        List<Integer> result = new ArrayList<>();
        File[] entries = new File("/proc").listFiles();
        if (entries == null) return result;
        int ownerPid = Process.myPid();
        for (File entry : entries) {
            int candidatePid;
            try { candidatePid = Integer.parseInt(entry.getName()); }
            catch (NumberFormatException ignored) { continue; }
            try {
                String commandLine = new String(
                        Files.readAllBytes(new File(entry, "cmdline").toPath()),
                        StandardCharsets.UTF_8);
                String processEnvironment = new String(
                        Files.readAllBytes(new File(entry, "environ").toPath()),
                        StandardCharsets.UTF_8);
                if (PhoneAudioBridgeProcessPolicy.isStaleBridge(
                        candidatePid, ownerPid, commandLine, processEnvironment, packageName)) {
                    result.add(candidatePid);
                }
            } catch (IOException | SecurityException ignored) {
                // Android hides most unrelated /proc entries. Same-UID bridge processes remain readable.
            }
        }
        return result;
    }

    private void monitorBridge(java.lang.Process launched) {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                launched.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                synchronized (lock) {
                    if (bridgeProcess == launched) pcmEvidence.observe(line);
                }
                Log.i("AirSIMPCM", line);
            }
        } catch (IOException error) {
            Log.w(TAG, "PCM log stream ended", error);
        }
        int exit = -1;
        try { exit = launched.waitFor(); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        boolean restart;
        synchronized (lock) {
            if (bridgeProcess == launched) bridgeProcess = null;
            restart = bridgeDesired && !shuttingDown;
        }
        Log.w(TAG, "PCM bridge exited code=" + exit + " restart=" + restart);
        if (restart) {
            try {
                Thread.sleep(1_000);
                ensureBridgeStarted();
            } catch (Throwable error) {
                Log.e(TAG, "PCM bridge restart failed", error);
            }
        }
    }

    private String setLocalOutputMuted(boolean muted) throws Exception {
        return setLocalOutputMuted(muted, "vowlan");
    }

    private String setLocalOutputMuted(boolean muted, String transport) throws Exception {
        return setLocalOutputMuted(muted, transport, "minimum_nonzero_volume");
    }

    private String setLocalOutputMuted(boolean muted, String transport, String policy) throws Exception {
        synchronized (audioLock) {
            verifyIdentity();
            if (muted && shuttingDown) throw new IOException("privileged service is stopping");
            LocalOutputMuteController.Strategy desired = LocalOutputMuteController.wireStrategy(policy);
            outputStrategy = "voble".equals(transport) ? "voble" : "vowlan";
            if (localIsolation != null && (!muted || desired != LocalOutputMuteController.Strategy.ISOLATE_LOCAL)) {
                isolationLease.revoke();
                localIsolation.setIsolated(false);
                localIsolation = null;
                if (!muted && outputMute == null) return "local_audio_isolation_restored verified=true";
            }
            if (!muted) {
                if (outputMute == null) return "local_output_unchanged";
                String result = outputMute.setMuted(false);
                outputMute = null;
                return result;
            }
            if (desired == LocalOutputMuteController.Strategy.ISOLATE_LOCAL) {
                synchronized (lock) {
                    if (bridgeOwnership == null)
                        throw new IOException("experimental isolation requires exclusive PCM ownership");
                }
                if (outputMute != null) {
                    outputMute.setMuted(false);
                    outputMute = null;
                }
                AudioManager audio = shellAudioManager();
                if (audioOperations.run(audio::getMode) != AudioManager.MODE_IN_CALL)
                    throw new IOException("physical audio isolation requires an answered carrier call");
                if (localIsolation == null) localIsolation = new LocalAudioIsolationController(isolationBackend(audio), isolationStore());
                isolationLease.renew(isolationClock.getAsLong());
                scheduleAudioRecovery();
                return localIsolation.setIsolated(true);
            }
            if (outputMute != null && !outputMute.policyName().equals(policy)) {
                // Restore the previous reduction before preserving user volume.
                // Keep the old snapshot if restoration fails so cleanup can retry.
                outputMute.setMuted(false);
                outputMute = null;
            }
            if (outputMute == null) outputMute = new LocalOutputMuteController(audioBackend(), desired);
            // A transport change does not own a new volume snapshot: all modes
            // obey this separate, user-selected output/capture policy.
            return outputMute.setMuted(true);
        }
    }

    private LocalAudioIsolationController.Store isolationStore() throws Exception {
        if (isolationStore == null) isolationStore = IsolationRecoveryJournal.forPackage(packageName);
        return isolationStore;
    }

    /** Restore a persisted same-boot snapshot before a restarted bridge accepts new media. */
    private void recoverInterruptedIsolation() throws Exception {
        synchronized (audioLock) {
            if (localIsolation != null) {
                if (localIsolation.restoring() || isolationLease.expired(isolationClock.getAsLong())) {
                    localIsolation.setIsolated(false);
                    localIsolation = null;
                }
                return;
            }
            if (isolationStore == null && (packageName.isEmpty() || !IsolationRecoveryJournal.hasSavedState(packageName))) return;
            if (isolationStore().read() == null) return;
            localIsolation = new LocalAudioIsolationController(isolationBackend(shellAudioManager()), isolationStore());
            isolationLease.revoke();
            scheduleAudioRecovery();
            localIsolation.setIsolated(false);
            localIsolation = null;
        }
    }

    private String renewIsolationLease() throws IOException {
        synchronized (audioLock) {
            verifyIdentity();
            if (shuttingDown) throw new IOException("privileged service is stopping");
            // Renewal cannot reapply isolation after expiry, failed cleanup, or another call.
            if (localIsolation != null && !localIsolation.restoring()
                    && !isolationLease.expired(isolationClock.getAsLong()))
                isolationLease.renew(isolationClock.getAsLong());
            return "isolation_lease_checked";
        }
    }

    /** Also runs after the App dies; no App callback or successful PCM query is required. */
    private void scheduleAudioRecovery() {
        if (recoveryTask == null || recoveryTask.isDone())
            recoveryTask = audioRecovery.scheduleWithFixedDelay(this::recoverAudioTick, 1, 1, TimeUnit.SECONDS);
    }

    private void recoverAudioTick() {
        synchronized (audioLock) {
            if (isolationClock.getAsLong() < nextRecoveryMillis) return;
            if (shuttingDown) { finishAudioShutdown(); return; }
            if (localIsolation == null) {
                if (recoveryTask != null) recoveryTask.cancel(false);
                recoveryTask = null;
                return;
            }
            if (!localIsolation.restoring() && !isolationLease.expired(isolationClock.getAsLong())) return;
            isolationLease.revoke();
            try {
                localIsolation.setIsolated(false);
                localIsolation = null;
                recoveryFailures = 0;
                nextRecoveryMillis = 0;
                Log.i(TAG, "experimental isolation restored after lease loss or failed operation");
            } catch (Exception error) {
                // Bounded operations cannot interrupt a late OEM write. Keep the original
                // snapshot and executor alive so the next tick restores AFTER that write.
                Log.w(TAG, "experimental isolation restoration pending", error);
                deferAudioRecovery();
            }
        }
    }

    private void deferAudioRecovery() {
        // Keep the recoverable snapshot, but do not hammer a failing OEM audio service.
        long delay = Math.min(10_000L, 1_000L << Math.min(recoveryFailures++, 4));
        recoveryFailures = Math.min(recoveryFailures, 5);
        nextRecoveryMillis = isolationClock.getAsLong() + delay;
    }

    private LocalAudioIsolationController.Api isolationBackend(AudioManager audio) throws Exception {
        SystemCallOutputPolicy policy = new SystemCallOutputPolicy();
        return new LocalAudioIsolationController.Api() {
            public boolean microphoneMuted() throws Exception {
                return audioOperations.run(audio::isMicrophoneMute);
            }
            public void microphoneMuted(boolean muted) throws Exception {
                audioOperations.run(() -> { audio.setMicrophoneMute(muted); return null; });
            }
            public boolean streamMuted() throws Exception {
                return audioOperations.run(() -> audio.isStreamMute(AudioManager.STREAM_VOICE_CALL));
            }
            public int index(int device) throws Exception {
                return audioOperations.run(() -> policy.index(device));
            }
            public void set(int device, int index, boolean muted) throws Exception {
                audioOperations.run(() -> { policy.set(device, index, muted); return null; });
            }
        };
    }

    private LocalOutputMuteController.Backend audioBackend() throws Exception {
        AudioManager audio = shellAudioManager();
        return new LocalOutputMuteController.Backend() {
            public boolean isMuted() throws Exception {
                return audioOperations.run(() -> audio.isStreamMute(AudioManager.STREAM_VOICE_CALL));
            }
            public int volume() throws Exception {
                return audioOperations.run(() -> audibleCallVolume(audio));
            }
            public int minimumVolume() throws Exception {
                return audioOperations.run(() -> audio.getStreamMinVolume(AudioManager.STREAM_VOICE_CALL));
            }
            public void setVolume(int volume) throws Exception {
                audioOperations.run(() -> { audio.setStreamVolume(AudioManager.STREAM_VOICE_CALL, volume, 0); return null; });
            }
            public void setMuted(boolean muted) throws Exception {
                audioOperations.run(() -> {
                    audio.adjustStreamVolume(AudioManager.STREAM_VOICE_CALL,
                            muted ? AudioManager.ADJUST_MUTE : AudioManager.ADJUST_UNMUTE, 0);
                    return null;
                });
            }
            public void prepareOutputMute(boolean originalMuted) throws Exception {
                if (!"samsung".equalsIgnoreCase(android.os.Build.MANUFACTURER)) return;
                callOutputPolicyMute = CallOutputPolicyMute.prepareWithin(
                        audioOperations, new SystemCallOutputPolicy(), originalMuted);
            }
            public void applyOutputMute() throws Exception {
                if (callOutputPolicyMute == null) return;
                audioOperations.run(() -> {
                    if (audio.getMode() != AudioManager.MODE_IN_CALL)
                        throw new IOException("cellular output is not in call mode");
                    callOutputPolicyMute.apply();
                    return null;
                });
            }
            public void restoreOutputMute() throws Exception {
                if (callOutputPolicyMute == null) return;
                audioOperations.run(() -> { callOutputPolicyMute.restore(); return null; });
            }
        };
    }

    private static int audibleCallVolume(AudioManager audio) throws Exception {
        if (!audio.isStreamMute(AudioManager.STREAM_VOICE_CALL))
            return audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
        // The zero reported while muted is not the stored audible volume index.
        return ((Number) AudioManager.class.getMethod("getLastAudibleStreamVolume", int.class)
                .invoke(audio, AudioManager.STREAM_VOICE_CALL)).intValue();
    }

    private String audioSnapshot() throws Exception {
        boolean pcmRunning;
        synchronized (lock) {
            verifyIdentity();
            pcmRunning = bridgeProcess != null && bridgeProcess.isAlive();
        }
        // Read-only OEM queries must not monopolize the lock needed to restore local audio.
        AudioManager audio = shellAudioManager();
        return audioOperations.run(() -> "muted=" + audio.isStreamMute(AudioManager.STREAM_VOICE_CALL)
                + " volume=" + (outputMute != null && outputMute.usesMinimumVolume()
                    ? audibleCallVolume(audio) : audio.getStreamVolume(AudioManager.STREAM_VOICE_CALL))
                + " mode=" + audio.getMode() + " speaker=" + audio.isSpeakerphoneOn()
                + " pcm=" + pcmRunning + " output_transport=" + outputStrategy + " output_policy="
                + outputPolicyDiagnostic()
                + isolationSnapshot(audio)
                + " " + pcmEvidence.snapshot());
    }

    /** Called inside the bounded read operation; do not nest an audioOperations.run here. */
    private String isolationSnapshot(AudioManager audio) throws Exception {
        if (localIsolation == null) return "";
        SystemCallOutputPolicy policy = new SystemCallOutputPolicy();
        return " mic_muted=" + audio.isMicrophoneMute()
                + " earpiece_index=" + policy.index(1) + " speaker_index=" + policy.index(2);
    }

    private String outputPolicyDiagnostic() {
        if (localIsolation != null) return "isolate_local";
        LocalOutputMuteController current = outputMute;
        if (current != null)
            return current.policyName() + (current.usesMinimumVolume()
                    ? " minimum_volume=" + current.targetMinimumVolume() : " independent_output_control=false");
        return callOutputPolicyMute != null && callOutputPolicyMute.applied() ? "zero_readback" : "not_applied";
    }

    private AudioManager shellAudioManager() throws Exception {
        Context context = serviceContext;
        if (context == null) {
            // Shizuku can instantiate a UserService without passing a Context.
            Class<?> activityThread = Class.forName("android.app.ActivityThread");
            Object thread = activityThread.getMethod("currentActivityThread").invoke(null);
            if (thread == null) thread = activityThread.getMethod("systemMain").invoke(null);
            context = (Context) activityThread.getMethod("getSystemContext").invoke(thread);
        }
        // Attribute public AudioManager operations to the actual shell UID, not the APK UID.
        Context shell = context.createPackageContext("com.android.shell", 0);
        AudioManager audio = shell.getSystemService(AudioManager.class);
        if (audio == null) throw new IOException("系统通话音频服务不可用");
        return audio;
    }

    private String ensureDialerRole() throws Exception {
        verifyIdentity();
        if (packageName.isEmpty()) throw new IOException("application package unavailable");
        String holders = runCommand(PrivilegedBridgeProtocol.dialerRoleQueryCommand());
        if (!PrivilegedBridgeProtocol.isDialerRoleHolder(holders, packageName)) {
            runCommand(PrivilegedBridgeProtocol.dialerRoleGrantCommand(packageName));
            holders = runCommand(PrivilegedBridgeProtocol.dialerRoleQueryCommand());
        }
        if (!PrivilegedBridgeProtocol.isDialerRoleHolder(holders, packageName)) {
            throw new IOException("dialer role was not applied by the system");
        }
        return "dialer_role=granted verified=true";
    }

    private String runCommand(String[] command) throws Exception {
        java.lang.Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (output.length() > 0) output.append('\n');
                output.append(line);
            }
        }
        if (!process.waitFor(3, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new IOException("privileged command timed out");
        }
        if (process.exitValue() != 0) throw new IOException("privileged command failed: " + output);
        return output.toString();
    }

    private String status() {
        synchronized (lock) {
            return statusLocked();
        }
    }

    private String statusLocked() {
        return "uid=" + Process.myUid()
                + " service_revision=14"
                + " pcm=" + (bridgeProcess != null && bridgeProcess.isAlive() ? "running" : "stopped")
                + " local_output=" + (localIsolation != null && localIsolation.verified() ? "isolated"
                    : outputMute != null && outputMute.isVerifiedMinimum() ? "minimum"
                    : outputMute != null && outputMute.isVerifiedMuted() ? "muted" : "normal")
                + " output_policy=" + outputPolicyDiagnostic()
                + " " + pcmEvidence.snapshot();
    }

    private void verifyIdentity() {
        if (!PrivilegedBridgeProtocol.supportsUid(Process.myUid())) {
            throw new SecurityException("Shizuku service is not shell/root uid");
        }
    }

    public void destroy() {
        shutdown();
        if (shutdownComplete.getCount() == 0) System.exit(0);
        else new Thread(() -> { awaitShutdown(); System.exit(0); }, "AirSIM-audio-exit").start();
    }

    synchronized void shutdown() {
        synchronized (lock) {
            if (shuttingDown) { return; } // Recovery continues independently until verified.
            shuttingDown = true;
            bridgeDesired = false;
            if (bridgeProcess != null) {
                bridgeProcess.destroy();
                try {
                    if (!bridgeProcess.waitFor(1, TimeUnit.SECONDS)) {
                        bridgeProcess.destroyForcibly();
                        bridgeProcess.waitFor(1, TimeUnit.SECONDS);
                    }
                } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
            }
            bridgeProcess = null;
        }
        synchronized (audioLock) {
            isolationLease.revoke();
            finishAudioShutdown();
        }
    }

    /** Keep both the recovery worker and PCM ownership until the original state is restored. */
    private void finishAudioShutdown() {
        if (shutdownComplete.getCount() == 0) return;
        try {
            setLocalOutputMuted(false);
            synchronized (lock) {
                if (bridgeOwnership != null) {
                    try { bridgeOwnership.close(); }
                    catch (IOException error) { Log.w(TAG, "PCM ownership close failed", error); }
                    bridgeOwnership = null;
                }
            }
            audioOperations.close();
            audioRecovery.shutdown();
            shutdownComplete.countDown();
        } catch (Exception error) {
            Log.w(TAG, "audio restore pending; retaining recovery worker and snapshot", error);
            deferAudioRecovery();
            scheduleAudioRecovery();
        }
    }

    void awaitShutdown() {
        boolean interrupted = false;
        for (;;) {
            try { shutdownComplete.await(); break; }
            catch (InterruptedException error) { interrupted = true; }
        }
        if (interrupted) Thread.currentThread().interrupt();
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }
}
