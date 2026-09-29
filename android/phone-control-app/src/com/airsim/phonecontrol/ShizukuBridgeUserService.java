package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

public final class ShizukuBridgeUserService extends Binder {
    private static final String TAG = "DJOneHubShizuku";
    private static final int DESTROY_TRANSACTION = 16777115;
    private static final int DESTROY_TRANSACTION_AIDL = 16777114;

    private final Object lock = new Object();
    private String sourceApk = "";
    private java.lang.Process bridgeProcess;
    private boolean bridgeDesired;
    private boolean muteCycleStarted;
    private boolean previousMuted;

    public ShizukuBridgeUserService() {
        Log.i(TAG, "created without context uid=" + Process.myUid());
    }

    public ShizukuBridgeUserService(Context context) {
        sourceApk = context.getApplicationInfo().sourceDir;
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
            List<String> command = new ArrayList<>();
            command.add("/system/bin/app_process");
            command.add("/system/bin");
            command.add("com.airsim.bridge.PhoneAudioBridge");
            command.add("--listen-interface");
            command.add("avf_tap_fixed");
            command.add("--listen-port");
            command.add("7580");
            ProcessBuilder builder = new ProcessBuilder(command).redirectErrorStream(true);
            builder.environment().put("CLASSPATH", sourceApk);
            bridgeProcess = builder.start();
            java.lang.Process launched = bridgeProcess;
            Thread monitor = new Thread(() -> monitorBridge(launched), "djonehub-shizuku-pcm-monitor");
            monitor.setDaemon(true);
            monitor.start();
            Log.i(TAG, "PCM bridge process started");
            return statusLocked();
        }
    }

    private void monitorBridge(java.lang.Process launched) {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                launched.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) Log.i("DJOneHubPCM", line);
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
        synchronized (lock) {
            verifyIdentity();
            if (muted && !muteCycleStarted) {
                previousMuted = queryVoiceCallMuted();
                muteCycleStarted = true;
            }
            if (muted) {
                if (!previousMuted) runCommand(PrivilegedBridgeProtocol.audioMuteCommand(true));
                boolean verified = queryVoiceCallMuted();
                if (!verified) throw new IOException("voice-call output mute was not applied");
                return "local_output_muted previous_muted=" + previousMuted + " verified=true";
            }
            if (muteCycleStarted && !previousMuted) {
                runCommand(PrivilegedBridgeProtocol.audioMuteCommand(false));
                if (queryVoiceCallMuted()) throw new IOException("voice-call output unmute was not applied");
            }
            boolean restoredPrevious = previousMuted;
            muteCycleStarted = false;
            previousMuted = false;
            return "local_output_restored previous_muted=" + restoredPrevious + " verified=true";
        }
    }

    private boolean queryVoiceCallMuted() throws Exception {
        return PrivilegedBridgeProtocol.isStreamMuted(runCommand(
                new String[]{"cmd", "audio", "get-stream-volume", "0"}));
    }

    private String runCommand(String[] command) throws Exception {
        java.lang.Process process = new ProcessBuilder(command).redirectErrorStream(true).start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!output.isEmpty()) output.append('\n');
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
                + " pcm=" + (bridgeProcess != null && bridgeProcess.isAlive() ? "running" : "stopped")
                + " local_output=" + (muteCycleStarted ? "muted" : "normal");
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
        System.exit(0);
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName() + (message == null ? "" : ": " + message);
    }
}
