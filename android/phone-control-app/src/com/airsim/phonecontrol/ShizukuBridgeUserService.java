package com.airsim.phonecontrol;

import android.content.Context;
import android.media.AudioManager;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

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
    private Context serviceContext;
    private volatile LocalOutputMuteController outputMute;
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
                case PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED ->
                        setLocalOutputMuted(data.readInt() != 0);
                case PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE -> ensureDialerRole();
                case PrivilegedBridgeProtocol.TRANSACTION_AUDIO_SNAPSHOT -> audioSnapshot();
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

    private String ensureBridgeStarted() throws IOException {
        synchronized (lock) {
            verifyIdentity();
            bridgeDesired = true;
            if (bridgeProcess != null && bridgeProcess.isAlive()) return statusLocked();
            if (sourceApk.isEmpty()) throw new IOException("application source path unavailable");
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
            restart = bridgeDesired;
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
        synchronized (audioLock) {
            verifyIdentity();
            if (outputMute == null && !muted) return "local_output_unchanged";
            if (outputMute == null) outputMute = new LocalOutputMuteController(audioBackend(),
                    "samsung".equalsIgnoreCase(android.os.Build.MANUFACTURER)
                        ? LocalOutputMuteController.Strategy.MINIMUM_VOLUME
                        : LocalOutputMuteController.Strategy.MUTE);
            return outputMute.setMuted(muted);
        }
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
                + " pcm=" + pcmRunning + " output_policy="
                + outputPolicyDiagnostic()
                + " " + pcmEvidence.snapshot());
    }

    private String outputPolicyDiagnostic() {
        LocalOutputMuteController current = outputMute;
        if (current != null && current.usesMinimumVolume())
            return "minimum_volume minimum_volume=" + current.targetMinimumVolume();
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
                + " service_revision=11"
                + " pcm=" + (bridgeProcess != null && bridgeProcess.isAlive() ? "running" : "stopped")
                + " local_output=" + (outputMute != null && outputMute.isVerifiedMinimum() ? "minimum"
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
        synchronized (lock) {
            bridgeDesired = false;
            if (bridgeProcess != null) bridgeProcess.destroy();
            bridgeProcess = null;
        }
        try { setLocalOutputMuted(false); }
        catch (Throwable error) { Log.w(TAG, "restore output during destroy failed", error); }
        audioOperations.close();
        System.exit(0);
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }
}
