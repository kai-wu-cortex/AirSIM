package com.airsim.bridge;

import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicBoolean;

public final class PhoneAudioBridge {
    enum PlaybackRoute {
        SAMSUNG_TAG,
        TELEPHONY_DEVICE,
        UNSUPPORTED
    }

    private static final int SAMPLE_RATE = 8000;
    private static final int CHANNEL_IN = AudioFormat.CHANNEL_IN_MONO;
    private static final int CHANNEL_OUT = AudioFormat.CHANNEL_OUT_MONO;
    private static final int ENCODING = AudioFormat.ENCODING_PCM_16BIT;
    private static final int ROUTE_VERIFY_TIMEOUT_MS = 2000;

    private PhoneAudioBridge() {}

    public static void main(String[] argv) {
        long started = SystemClock.elapsedRealtime();
        BridgeStats stats = new BridgeStats();
        try {
            BridgeArguments arguments = BridgeArguments.parse(argv);
            serve(arguments, started, stats);
        } catch (Throwable error) {
            emit(started, "bridge_error", Map.of(
                "error_class", error.getClass().getName(),
                "error_message", safeMessage(error),
                "result", "error"));
            error.printStackTrace(System.err);
            System.exit(2);
        }
    }

    static int captureSource() {
        return 3;
    }

    static int playbackUsage() {
        return AudioAttributes.USAGE_VOICE_COMMUNICATION;
    }

    static String[] playbackTags() {
        return new String[] {"VOICE_TX"};
    }

    static PlaybackRoute playbackRoute(
            boolean samsungTagAvailable, boolean telephonyDeviceAvailable) {
        if (samsungTagAvailable) return PlaybackRoute.SAMSUNG_TAG;
        if (telephonyDeviceAvailable) return PlaybackRoute.TELEPHONY_DEVICE;
        return PlaybackRoute.UNSUPPORTED;
    }

    static long listenerRetryDelayMillis(int consecutiveFailures) {
        int boundedFailures = Math.max(1, Math.min(consecutiveFailures, 20));
        return Math.min(5000L, boundedFailures * 250L);
    }

    static boolean voiceTxRouteTimedOut(
            boolean routeVerified, long firstPlaybackAt, long now) {
        return !routeVerified
            && firstPlaybackAt != 0
            && now - firstPlaybackAt >= ROUTE_VERIFY_TIMEOUT_MS;
    }

    private static void serve(BridgeArguments arguments, long started, BridgeStats stats) {
        BridgeSessionGate gate = new BridgeSessionGate();
        int consecutiveFailures = 0;
        while (true) {
            try {
                InetAddress address = resolveListenAddress(arguments);
                try (ServerSocket server = new ServerSocket()) {
                    server.setReuseAddress(true);
                    server.bind(new InetSocketAddress(address, arguments.listenPort()), 4);
                    consecutiveFailures = 0;
                    emit(started, "bridge_listening", Map.of(
                        "listen_host", address.getHostAddress(),
                        "listen_interface", arguments.listenInterface() == null ? "explicit" : arguments.listenInterface(),
                        "listen_port", arguments.listenPort(),
                        "model", Build.MODEL,
                        "sample_rate", SAMPLE_RATE,
                        "frame_bytes", BridgeProtocol.FRAME_BYTES,
                        "result", "ok"));
                    emit(started, "audio_capabilities", AudioCapabilityProbe.inspect());
                    while (!server.isClosed()) {
                        Socket client = server.accept();
                        if (!gate.tryAcquire(client)) {
                            stats.recordRejectedClient();
                            emit(started, "client_rejected", statsFields(stats.snapshot()));
                            client.close();
                            continue;
                        }
                        Thread session = new Thread(() -> {
                            try {
                                handleClient(client, started, stats);
                            } finally {
                                gate.release(client);
                            }
                        }, "airsim-phone-audio-session");
                        session.start();
                    }
                }
            } catch (IOException error) {
                consecutiveFailures++;
                long retryDelay = listenerRetryDelayMillis(consecutiveFailures);
                emit(started, "listener_restarting", Map.of(
                    "attempt", consecutiveFailures,
                    "error_class", error.getClass().getName(),
                    "error_message", safeMessage(error),
                    "retry_delay_ms", retryDelay,
                    "result", "retrying"));
                SystemClock.sleep(retryDelay);
            }
        }
    }

    private static InetAddress resolveListenAddress(BridgeArguments arguments) throws IOException {
        if (arguments.listenHost() != null) return InetAddress.getByName(arguments.listenHost());
        NetworkInterface network = NetworkInterface.getByName(arguments.listenInterface());
        if (network == null || !network.isUp() || network.isLoopback()) {
            throw new IOException("AVF interface unavailable: " + arguments.listenInterface());
        }
        Enumeration<InetAddress> addresses = network.getInetAddresses();
        while (addresses.hasMoreElements()) {
            InetAddress address = addresses.nextElement();
            if (address.getAddress().length == 4 && address.isSiteLocalAddress()) return address;
        }
        throw new IOException("AVF private IPv4 unavailable: " + arguments.listenInterface());
    }

    private static void handleClient(Socket client, long started, BridgeStats stats) {
        boolean probe = false;
        try (client) {
            client.setKeepAlive(true);
            client.setTcpNoDelay(true);
            client.setSoTimeout(3_000);
            // Validate the hello before touching audio endpoints. A bare TCP
            // liveness probe (VoWLANGatewayService.portOpen) closes immediately;
            // never start AudioRecord/AudioTrack or record a session failure for it.
            boolean receiveOnly = BridgeProtocol.readMediaHello(client.getInputStream());
            if (receiveOnly) streamEarlyAudio(client, started, stats);
            else streamCallAudio(client, started, stats);
        } catch (BridgeProtocol.ProbeClosed closed) {
            probe = true;
        } catch (Throwable error) {
            emit(started, "session_error", error instanceof AudioStartupFailure failure
                ? failure.diagnosticFields() : Map.of(
                "error_class", error.getClass().getName(),
                "error_message", safeMessage(error),
                "result", "error"));
        } finally {
            if (!probe) emit(started, "client_closed", statsFields(stats.snapshot()));
        }
    }

    private static void streamEarlyAudio(Socket client, long started, BridgeStats stats) throws Exception {
        String phase="select_capture_route";
        try {
            if (!Redmi9PCMProfile.matches(Build.MANUFACTURER, Build.DEVICE, Build.HARDWARE))
                throw new IllegalStateException("receive-only profile unavailable");
            AudioDeviceInfo rx=findTelephonyDevice(true);
            if(rx==null || !Redmi9PCMProfile.supports(rx.getSampleRates(),rx.getChannelCounts(),rx.getEncodings(),8000,1))
                throw new IllegalStateException("Telephony Rx unavailable");
            phase="create_capture";
            int buffer=AudioRecord.getMinBufferSize(SAMPLE_RATE,CHANNEL_IN,ENCODING);
            if(buffer<=0) throw new IllegalStateException("invalid capture buffer");
            AudioRecord recorder=new AudioRecord(captureSource(),SAMPLE_RATE,CHANNEL_IN,ENCODING,Math.max(buffer,BridgeProtocol.FRAME_BYTES*10));
            Object lifecycle=new Object();
            AtomicBoolean running=new AtomicBoolean(true);
            Runnable stop=() -> {
                if(!running.compareAndSet(true,false)) return;
                try { client.close(); } catch(IOException ignored) {}
                synchronized(lifecycle) {
                    try { if(recorder.getRecordingState()==AudioRecord.RECORDSTATE_RECORDING) recorder.stop(); }
                    catch(RuntimeException ignored) {}
                }
            };
            try (AudioEndpointLease capture = new AudioEndpointLease(() -> {
                    synchronized(lifecycle) { if(recorder.getRecordingState()==AudioRecord.RECORDSTATE_RECORDING) recorder.stop(); }
                }, () -> { synchronized(lifecycle) { recorder.release(); } })) {
                try {
                phase="bind_capture_route";
                if(!recorder.setPreferredDevice(rx)) throw new IllegalStateException("Telephony Rx rejected");
                phase="validate_capture";
                if(recorder.getState()!=AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("capture unavailable");
                phase="start_capture";
                recorder.startRecording();
                phase="verify_capture";
                if(recorder.getRecordingState()!=AudioRecord.RECORDSTATE_RECORDING) throw new IOException("capture not recording");
                phase="send_ready";
                BridgeProtocol.writeReady(client.getOutputStream());
                stats.resetAudio();
                emit(started,"audio_profile",Map.of("profile","redmi9_mtk_experimental","direction","recvonly","capture_rate",8000,"capture_source","voice_downlink"));
                emit(started,"client_ready",Map.of("result","receive_only_capture","route_verified",false));
                client.setSoTimeout(0);
                Thread disconnect=new Thread(() -> {
                    try { client.getInputStream().read(); } catch(IOException ignored) {}
                    finally { stop.run(); }
                },"airsim-early-disconnect");
                disconnect.setDaemon(true); disconnect.start();
                Thread reporter=new Thread(() -> reportStats(started,stats,running),"airsim-early-stats");
                reporter.setDaemon(true); reporter.start();
                try { captureDownlink(recorder,true,client,stats,running,stop,true); }
                finally { stop.run(); reporter.interrupt(); }
                } finally { stop.run(); }
            }
        } catch (Exception | LinkageError error) { throw new AudioStartupFailure(phase,error); }
    }

    private static void streamCallAudio(Socket client, long started, BridgeStats stats)
            throws Exception {
        // Only the synchronous handshake callback mutates this phase holder.
        String[] phase = {"buffer_sizes"};
        try {
            stats.resetAudio();
            emit(started, "audio_initializing", Map.of("result", "starting"));
            boolean redmi9 = Redmi9PCMProfile.matches(Build.MANUFACTURER, Build.DEVICE, Build.HARDWARE);
            int recordBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_IN, ENCODING);
            // Redmi's playback size is queried after selecting its declared HAL
            // profile; rejecting 8k mono here would prevent the native-format path.
            int trackBufferSize = redmi9 ? BridgeProtocol.FRAME_BYTES
                    : AudioTrack.getMinBufferSize(SAMPLE_RATE, CHANNEL_OUT, ENCODING);
            if (recordBufferSize <= 0 || trackBufferSize <= 0) {
                throw new IllegalStateException("invalid Android audio buffer sizes");
            }

            phase[0] = "create_capture";
            AudioRecord recorder = new AudioRecord(
                captureSource(), SAMPLE_RATE, CHANNEL_IN, ENCODING,
                Math.max(recordBufferSize, BridgeProtocol.FRAME_BYTES * 10));
            try (AudioEndpointLease capture = new AudioEndpointLease(() -> {
                    if (recorder.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) recorder.stop();
                }, recorder::release)) {
                if (redmi9) {
                    phase[0] = "select_capture_route";
                    AudioDeviceInfo rx = findTelephonyDevice(true);
                    if (rx == null || !Redmi9PCMProfile.supports(rx.getSampleRates(), rx.getChannelCounts(), rx.getEncodings(), 8000, 1)) {
                        throw new IllegalStateException("Redmi 9 Telephony Rx 8k mono PCM16 unavailable");
                    }
                    phase[0] = "bind_capture_route";
                    if (!recorder.setPreferredDevice(rx)) throw new IllegalStateException("Telephony Rx route rejected");
                }
                phase[0] = "create_attributes";
                AudioAttributes.Builder attributeBuilder = new AudioAttributes.Builder()
                    .setUsage(playbackUsage())
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH);
                phase[0] = "select_uplink_route";
                boolean samsungTagAvailable = tryAddSamsungVoiceTxTag(attributeBuilder);
                AudioDeviceInfo telephonyTx = samsungTagAvailable ? null : findTelephonyTxDevice();
                PlaybackRoute playbackRoute = playbackRoute(
                    samsungTagAvailable, telephonyTx != null);
                if (playbackRoute == PlaybackRoute.UNSUPPORTED) {
                    throw new IllegalStateException(
                        "neither Samsung VOICE_TX nor Android Telephony Tx is available");
                }
                phase[0] = "select_playback_format";
                int playbackRate = redmi9 && telephonyTx != null ? Redmi9PCMProfile.playbackRate(
                        telephonyTx.getSampleRates(), telephonyTx.getChannelCounts(), telephonyTx.getEncodings()) : SAMPLE_RATE;
                boolean convertUplink = playbackRate == 48000;
                int playbackChannels = convertUplink ? AudioFormat.CHANNEL_OUT_STEREO : CHANNEL_OUT;
                trackBufferSize = AudioTrack.getMinBufferSize(playbackRate, playbackChannels, ENCODING);
                if (trackBufferSize <= 0) throw new IllegalStateException("invalid playback format buffer");
                phase[0] = "create_playback";
                AudioTrack track = new AudioTrack.Builder()
                    .setAudioAttributes(attributeBuilder.build())
                    .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(playbackRate)
                        .setChannelMask(playbackChannels)
                        .build())
                    .setBufferSizeInBytes(Math.max(trackBufferSize, BridgeProtocol.FRAME_BYTES * (convertUplink ? 48 : 10)))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
                try (AudioEndpointLease playback = new AudioEndpointLease(() -> {
                        if (track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING) track.stop();
                    }, track::release)) {
                    phase[0] = "bind_uplink_route";
                    if (playbackRoute == PlaybackRoute.TELEPHONY_DEVICE
                            && !track.setPreferredDevice(telephonyTx)) {
                        throw new IllegalStateException("Android Telephony Tx route was rejected");
                    }
                    phase[0] = "validate_capture";
                    if (recorder.getState() != AudioRecord.STATE_INITIALIZED) {
                        throw new IllegalStateException("VOICE_DOWNLINK AudioRecord initialization failed");
                    }
                    phase[0] = "validate_playback";
                    if (track.getState() != AudioTrack.STATE_INITIALIZED) {
                        throw new IllegalStateException("VOICE_TX AudioTrack initialization failed");
                    }
                    emit(started, "audio_initialized", Map.of(
                        "audio_session_id", recorder.getAudioSessionId(),
                        "capture_source", "voice_downlink",
                        "playback_route", playbackRoute.name().toLowerCase(),
                        "record_buffer_bytes", recordBufferSize,
                        "track_buffer_bytes", trackBufferSize,
                        "result", "ok"));
                    emit(started, "audio_profile", Map.of("profile", redmi9 ? "redmi9_mtk_experimental" : "standard",
                        "wire_rate", SAMPLE_RATE, "capture_source", "voice_downlink", "capture_rate", SAMPLE_RATE,
                        "playback_rate", playbackRate, "playback_channels", convertUplink ? 2 : 1));

                    // The hello was validated before any audio endpoint was created.
                    // Start the real endpoints, then send READY; a successful TCP
                    // handshake alone is not evidence of usable call audio.
                    phase[0] = "start_capture";
                    recorder.startRecording();
                    phase[0] = "start_playback";
                    track.play();
                    phase[0] = "verify_capture";
                    if (recorder.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                        throw new IOException("VOICE_DOWNLINK AudioRecord did not start");
                    }
                    phase[0] = "send_ready";
                    BridgeProtocol.writeReady(client.getOutputStream());
                    emit(started, "client_ready", Map.of("result", "audio_initialized", "route_verified", false));

                    phase[0] = "stream_audio";
                    AtomicBoolean running = new AtomicBoolean(true);
                    Runnable stop = () -> {
                        if (running.compareAndSet(true, false)) {
                            try {
                                client.close();
                            } catch (IOException ignored) {
                            }
                        }
                    };
                    Thread downlink = new Thread(
                        () -> captureDownlink(recorder, redmi9, client, stats, running, stop),
                        "airsim-phone-downlink");
                    Thread uplink = new Thread(
                        () -> playUplink(track, playbackRoute, redmi9, convertUplink, client, started, stats, running, stop),
                        "airsim-phone-uplink");
                    Thread reporter = new Thread(
                        () -> reportStats(started, stats, running),
                        "airsim-phone-stats");
                    downlink.start();
                    uplink.start();
                    reporter.start();
                    downlink.join();
                    uplink.join();
                    running.set(false);
                    reporter.interrupt();
                    reporter.join();
                }
            }
        } catch (Exception | LinkageError error) {
            throw new AudioStartupFailure(phase[0], error);
        }
    }

    private static void captureDownlink(
            AudioRecord recorder,
            boolean strictTelephony,
            Socket client,
            BridgeStats stats,
            AtomicBoolean running,
            Runnable stop) {
        captureDownlink(recorder, strictTelephony, client, stats, running, stop, false);
    }

    private static void captureDownlink(AudioRecord recorder, boolean strictTelephony, Socket client,
            BridgeStats stats, AtomicBoolean running, Runnable stop, boolean awaitAudibleFrame) {
        byte[] frame = new byte[BridgeProtocol.FRAME_BYTES];
        long nextRouteProbe = 0;
        try {
            OutputStream output = client.getOutputStream();
            while (running.get()) {
                int count = recorder.read(frame, 0, frame.length, AudioRecord.READ_BLOCKING);
                if (count < 0) {
                    throw new IOException("AudioRecord read failed: " + count);
                }
                int evenCount = count & ~1;
                if (evenCount == 0) {
                    continue;
                }
                if (strictTelephony && SystemClock.elapsedRealtime() >= nextRouteProbe) {
                    nextRouteProbe = SystemClock.elapsedRealtime() + 1000;
                    String route = "unknown", silenced = "unknown";
                    try {
                        AudioDeviceInfo device = recorder.getRoutedDevice();
                        route = device == null ? "unknown" : device.isSource() && device.getType() == AudioDeviceInfo.TYPE_TELEPHONY
                                ? "telephony" : "other";
                        android.media.AudioRecordingConfiguration config = recorder.getActiveRecordingConfiguration();
                        if (config != null) silenced = config.isClientSilenced() ? "yes" : "no";
                    } catch (RuntimeException | LinkageError ignored) { /* Missing metadata is not verified routing. */ }
                    emit(0, "capture_route_observed", Map.of("capture_route", route, "capture_silenced", silenced));
                    if (strictTelephony && route.equals("other")) throw new IOException("capture is not routed to Telephony Rx");
                }
                if (awaitAudibleFrame) {
                    if (!hasSignal(frame, evenCount)) continue;
                    awaitAudibleFrame = false;
                    emit(0, "early_media_signal_observed", Map.of("direction", "recvonly"));
                }
                if (!running.get()) break;
                output.write(frame, 0, evenCount);
                stats.recordDownlink(frame, evenCount);
            }
        } catch (Throwable error) {
            if (running.get()) {
                emit(0, "downlink_error", Map.of(
                    "error_class", error.getClass().getName(),
                    "error_message", safeMessage(error)));
            }
        } finally {
            Arrays.fill(frame, (byte) 0);
            stop.run();
        }
    }

    static boolean hasSignal(byte[] frame, int count) {
        for (int i=0;i+1<count;i+=2) {
            int sample=(short)((frame[i]&255)|(frame[i+1]<<8));
            if(sample>1 || sample<-1) return true;
        }
        return false;
    }

    private static void playUplink(
            AudioTrack track,
            PlaybackRoute playbackRoute,
            boolean strictTelephony,
            boolean convertUplink,
            Socket client,
            long started,
            BridgeStats stats,
            AtomicBoolean running,
            Runnable stop) {
        byte[] frame = new byte[BridgeProtocol.FRAME_BYTES];
        byte[] nativeFrame = convertUplink ? new byte[BridgeProtocol.FRAME_BYTES * 12] : frame;
        PCM8kTo48kStereo converter = convertUplink ? new PCM8kTo48kStereo() : null;
        long firstPlaybackAt = 0;
        // A vendor tag is a routing request, not proof of the route actually used.
        // Hidden Samsung routes may remain unverified: report that honestly,
        // without destroying a working downlink or falling back to the loudspeaker.
        boolean routeVerified = false;
        boolean routeWarningEmitted = false;
        int observedRouteID = -1;
        int observedRouteType = -1;
        try {
            client.setSoTimeout(250);
            InputStream input = client.getInputStream();
            while (running.get()) {
                int count;
                try {
                    count = readFrame(input, frame);
                } catch (SocketTimeoutException timeout) {
                    if (!routeWarningEmitted && voiceTxRouteTimedOut(
                            routeVerified, firstPlaybackAt, SystemClock.elapsedRealtime())) {
                        routeWarningEmitted = true;
                        emit(started, "voice_tx_route_unverified", Map.of(
                                "playback_route", playbackRoute.name().toLowerCase(),
                                "result", "degraded"));
                    }
                    continue;
                }
                if (count < 0) {
                    return;
                }
                AudioDeviceInfo beforeWrite = strictTelephony ? track.getRoutedDevice() : null;
                if (beforeWrite != null && beforeWrite.getType() != AudioDeviceInfo.TYPE_TELEPHONY)
                    throw new IOException("playback is not routed to Telephony Tx");
                int nativeCount = converter == null ? count : converter.convert(frame, count, nativeFrame);
                writeTrackFrame(track, nativeFrame, nativeCount);
                stats.recordUplink(frame, count);
                if (firstPlaybackAt == 0) {
                    firstPlaybackAt = SystemClock.elapsedRealtime();
                }
                AudioDeviceInfo routed = track.getRoutedDevice();
                int routedID = routed == null ? -1 : routed.getId();
                int routedType = routed == null ? -1 : routed.getType();
                if (routedID != observedRouteID || routedType != observedRouteType) {
                    observedRouteID = routedID;
                    observedRouteType = routedType;
                    // A route may change mid-call. Old verification is not evidence
                    // for the new destination, even while PCM bytes still advance.
                    routeVerified = false;
                    emit(started, "voice_tx_route_observed", Map.of(
                        "playback_route", playbackRoute.name().toLowerCase(),
                        "device_id", routedID,
                        "device_type", routedType,
                        "telephony_sink", routedType == AudioDeviceInfo.TYPE_TELEPHONY,
                        "route_kind", routed == null ? "unknown" : routedType == AudioDeviceInfo.TYPE_TELEPHONY ? "telephony" : "other",
                        "result", "observed"));
                }
                if (strictTelephony && routed != null && routedType != AudioDeviceInfo.TYPE_TELEPHONY)
                    throw new IOException("playback changed away from Telephony Tx");
                if (!routeVerified && routed != null
                        && routed.getType() == AudioDeviceInfo.TYPE_TELEPHONY) {
                    routeVerified = true;
                    emit(started, "voice_tx_route_verified", Map.of(
                        "device_id", routed.getId(),
                        "device_type", routed.getType(),
                        "result", "ok"));
                }
                if (!routeWarningEmitted && voiceTxRouteTimedOut(
                        routeVerified, firstPlaybackAt, SystemClock.elapsedRealtime())) {
                    // Do not tear down capture/downlink just because an OEM does not
                    // report its hidden telephony sink. Keep the call alive and expose
                    // the degraded route through diagnostics.
                    routeWarningEmitted = true;
                    emit(started, "voice_tx_route_unverified", Map.of(
                            "playback_route", playbackRoute.name().toLowerCase(),
                            "result", "degraded"));
                }
            }
        } catch (Throwable error) {
            if (running.get()) {
                emit(started, "uplink_error", Map.of(
                    "error_class", error.getClass().getName(),
                    "error_message", safeMessage(error)));
            }
        } finally {
            Arrays.fill(frame, (byte) 0);
            Arrays.fill(nativeFrame, (byte) 0);
            stop.run();
        }
    }

    private static int readFrame(InputStream input, byte[] frame) throws IOException {
        int offset = 0;
        while (offset < frame.length) {
            int count = input.read(frame, offset, frame.length - offset);
            if (count < 0) {
                return offset == 0 ? -1 : offset;
            }
            if (count > 0) {
                offset += count;
            }
        }
        return offset;
    }

    private static void writeTrackFrame(AudioTrack track, byte[] frame, int count)
            throws IOException {
        int offset = 0;
        while (offset < count) {
            int written = track.write(frame, offset, count - offset, AudioTrack.WRITE_BLOCKING);
            if (written < 0) {
                throw new IOException("AudioTrack write failed: " + written);
            }
            if (written == 0) {
                continue;
            }
            offset += written;
        }
    }

    private static boolean tryAddSamsungVoiceTxTag(AudioAttributes.Builder builder) {
        try {
            Method addTag = AudioAttributes.Builder.class.getMethod(
                "semAddAudioTag", String.class);
            for (String tag : playbackTags()) {
                addTag.invoke(builder, tag);
            }
            return true;
        } catch (NoSuchMethodException | IllegalAccessException
                | InvocationTargetException error) {
            return false;
        }
    }

    private static AudioDeviceInfo findTelephonyTxDevice() {
        return findTelephonyDevice(false);
    }

    private static AudioDeviceInfo findTelephonyDevice(boolean input) {
        try {
            Method getDevices = AudioManager.class.getMethod("getDevicesStatic", int.class);
            AudioDeviceInfo[] devices = (AudioDeviceInfo[]) getDevices.invoke(
                null, input ? AudioManager.GET_DEVICES_INPUTS : AudioManager.GET_DEVICES_OUTPUTS);
            for (AudioDeviceInfo device : devices) {
                if ((input ? device.isSource() : device.isSink()) && device.getType() == AudioDeviceInfo.TYPE_TELEPHONY) {
                    return device;
                }
            }
        } catch (NoSuchMethodException | IllegalAccessException
                | InvocationTargetException | ClassCastException error) {
            // A denied/unavailable OEM query is not evidence of an empty device list.
            // Keep its cause so diagnostics can distinguish permissions from no Tx sink.
            throw new IllegalStateException("Android Telephony Tx device query failed", error);
        }
        return null;
    }

    private static void reportStats(long started, BridgeStats stats, AtomicBoolean running) {
        while (running.get()) {
            try {
                Thread.sleep(1000);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
            if (running.get()) {
                emit(started, "pcm_stats", statsFields(stats.snapshot()));
            }
        }
    }

    private static Map<String, Object> statsFields(BridgeStats.Snapshot snapshot) {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("downlink_bytes", snapshot.downlinkBytes());
        fields.put("downlink_frames", snapshot.downlinkFrames());
        fields.put("downlink_peak", snapshot.downlinkPeak());
        // Nonzero samples are diagnostic evidence, not proof of intelligibility
        // or of acoustic silence on the Android handset.
        fields.put("downlink_signal", snapshot.downlinkSignal());
        fields.put("uplink_bytes", snapshot.uplinkBytes());
        fields.put("uplink_frames", snapshot.uplinkFrames());
        fields.put("uplink_peak", snapshot.uplinkPeak());
        fields.put("rejected_clients", snapshot.rejectedClients());
        return fields;
    }

    private static synchronized void emit(
            long started,
            String event,
            Map<String, ?> extra) {
        Map<String, Object> fields = new TreeMap<>();
        fields.put("component", "android_audio_bridge");
        fields.put("elapsed_ms", started == 0 ? 0 : SystemClock.elapsedRealtime() - started);
        fields.put("event", event);
        fields.put("pid", Process.myPid());
        fields.put("protocol", "airsimpcm1");
        fields.put("sdk", Build.VERSION.SDK_INT);
        fields.put("uid", Process.myUid());
        fields.putAll(extra);
        System.out.println(json(fields));
    }

    private static String json(Map<String, ?> fields) {
        StringBuilder output = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, ?> entry : fields.entrySet()) {
            if (!first) {
                output.append(',');
            }
            first = false;
            output.append('"').append(escape(entry.getKey())).append("\":");
            Object value = entry.getValue();
            if (value == null) {
                output.append("null");
            } else if (value instanceof Number || value instanceof Boolean) {
                output.append(value);
            } else {
                output.append('"').append(escape(String.valueOf(value))).append('"');
            }
        }
        return output.append('}').toString();
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t");
    }

    private static String safeMessage(Throwable error) {
        String message = error.getMessage();
        return message == null ? "" : message.replace('\n', ' ').replace('\r', ' ');
    }
}
