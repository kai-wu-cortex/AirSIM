package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.app.role.RoleManager;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkRequest;
import android.net.NetworkCapabilities;
import android.net.LinkProperties;
import android.os.IBinder;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.util.Enumeration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class VoWLANGatewayService extends Service {
    // DJOneHub owns 7590/7591 on devices where both apps are installed.
    // AirSIM advertises these independent ports through Bonjour.
    public static final int CONTROL_PORT = 7592;
    public static final int PCM_PORT = 7593;

    // Both ports may shift when the preferred one is taken; clients must be told the
    // port actually in use rather than assuming the constant.
    private static volatile int activeControlPort = CONTROL_PORT;
    private static volatile int activePcmPort = PCM_PORT;

    public static int activeControlPort() {
        return activeControlPort;
    }

    public static int activePcmPort() {
        return activePcmPort;
    }

    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final NotificationUpdateGate notificationGate = new NotificationUpdateGate();
    private volatile boolean running;
    private final VoWLANNetworkRecoveryGate networkRecovery = new VoWLANNetworkRecoveryGate();
    private final Map<Network, String> wifiNetworks = new HashMap<>();
    private final Object networkSignal = new Object();
    private boolean networkWakeRequested;
    private ConnectivityManager connectivity;
    private ConnectivityManager.NetworkCallback networkCallback;
    private VoWLANControlGateway control;
    private VoWLANPCMRelay pcm;
    private record ExtraGateway(VoWLANControlGateway control, VoWLANPCMRelay pcm) {}
    private final Map<String, ExtraGateway> extraGateways = new HashMap<>();
    static final DirectGatewayRoutes DIRECT_ROUTES = new DirectGatewayRoutes();
    private volatile NsdManager.RegistrationListener advertisement;
    private final VoWLANAdvertisementEpoch advertisementEpoch = new VoWLANAdvertisementEpoch();
    private volatile long advertisementRetryAt;
    private String activeHotspot = "";
    private String lastDiagnosticState = "";
    private static volatile String currentDiagnosticState = "尚未检查";

    static String currentDiagnosticState() {
        return currentDiagnosticState;
    }

    public static void start(Context context) {
        BridgeLog.debug("vowlan_service_start_requested");
        try { context.startForegroundService(new Intent(context, VoWLANGatewayService.class)); }
        catch (RuntimeException error) { BridgeLog.error("vowlan_service_start_failed", error); }
    }

    @Override public void onCreate() {
        super.onCreate();
        currentDiagnosticState = "服务正在启动";
        BridgeLog.info("vowlan_service_created");
        startForeground(BridgeNotification.VOWLAN_ID, BridgeNotification.vowlan(this, "正在发现 VoWLAN 网络"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING);
        running = true;
        observeWiFiNetworks();
        worker.execute(this::lifecycleLoop);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void lifecycleLoop() {
        while (running) {
            try {
                if (networkRecovery.consume(android.os.SystemClock.elapsedRealtime())) {
                    // Re-register discovery only. Never tear down a working control/PCM socket.
                    invalidateAdvertisementForNetworkChange();
                    BridgeLog.watchdog("vowlan_network_recovery action=republish_discovery sockets=preserved");
                }
                Inet4Address hotspot = findAddress(true);
                List<Inet4Address> extraAddresses = additionalAddresses();
                Inet4Address avf = RuntimeMode.isStandalone(this)
                        ? (Inet4Address) InetAddress.getByName("127.0.0.1") : findAddress(false);
                if (!activeHotspot.isEmpty() && (hotspot == null || !hotspot.getHostAddress().equals(activeHotspot))
                        && ((control != null && control.ownsCall()) || (pcm != null && pcm.hasActiveSession()))) {
                    BridgeLog.info("hotspot_lost_no_midcall_handover action=end_current_call");
                    DirectCallOwnership.disconnectHost(activeHotspot);
                }
                boolean paired = VoWLANPairingStore.configured(this);
                RoleManager roleManager = getSystemService(RoleManager.class);
                boolean dialerRoleHeld = roleManager != null
                        && roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)
                        && roleManager.isRoleHeld(RoleManager.ROLE_DIALER);
                boolean agentReady = false;
                boolean pcmReady = false;
                if (avf != null && paired && AppConfig.configured(this)) {
                    boolean sameRunningGateway = (control != null && control.localPort() > 0
                            && pcm != null && pcm.localPort() > 0) || !extraGateways.isEmpty();
                    if (sameRunningGateway) {
                        // 不用空 TCP 探针打扰正在使用的单会话 PCM bridge。已启动的 relay
                        // 会在真实客户端连接时完成内部握手并报告精确错误。
                        agentReady = true;
                        pcmReady = true;
                    } else {
                        try {
                            String status = new AgentClient(this).status();
                            agentReady = status.contains("\"configured\":true") || status.contains("\"ok\":true");
                        } catch (Exception error) {
                            BridgeLog.error("vowlan_agent_probe_failed", error);
                        }
                        pcmReady = portOpen(avf, 7580);
                    }
                }
                diagnosticState(hotspot, avf, paired, agentReady, pcmReady, dialerRoleHeld);
                if (VoWLANNetworkPolicy.shouldAdvertise(
                        hotspot != null || !extraAddresses.isEmpty(), paired, agentReady, pcmReady, dialerRoleHeld)) {
                    // A Wi-Fi gateway and a userspace-VPN loopback gateway coexist.
                    // Never close the active VPN call because Wi-Fi disappeared.
                    if (hotspot != null) ensureStarted(hotspot, avf);
                    else stopPrimaryGateway();
                    syncAdditionalGateways(extraAddresses, avf);
                    update(hotspot != null ? "VoWLAN 就绪 · " + hotspot.getHostAddress()
                            : "手动直连网关就绪 · 可通过 Tailscale 连接");
                } else {
                    stopGateways();
                    update(!dialerRoleHeld ? "请将 AirSIM 设为默认电话应用"
                            : !paired ? "VoWLAN 未配对"
                            : hotspot == null ? "正在等待同网 Wi-Fi 或三星热点"
                            : !agentReady ? RuntimeMode.agentLabel(this) + " 尚未就绪" : "PCM 音频桥尚未就绪");
                }
                waitForNetworkCycle(networkRecovery.nextDelay(android.os.SystemClock.elapsedRealtime(), 5_000));
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception error) {
                currentDiagnosticState = "服务异常：" + error.getClass().getSimpleName();
                BridgeLog.error("vowlan_lifecycle_failed", error);
                stopGateways();
                update("VoWLAN 正在恢复");
                try { Thread.sleep(2_000); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); return; }
            }
        }
    }

    private void observeWiFiNetworks() {
        connectivity = getSystemService(ConnectivityManager.class);
        if (connectivity == null) return;
        ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) { changed(network, "available", false); }
            @Override public void onLost(Network network) { changed(network, "", true); }
            @Override public void onLinkPropertiesChanged(Network network, LinkProperties properties) {
                List<String> addresses = new ArrayList<>();
                for (android.net.LinkAddress address : properties.getLinkAddresses()) {
                    if (address.getAddress() instanceof Inet4Address) addresses.add(address.getAddress().getHostAddress());
                }
                java.util.Collections.sort(addresses);
                changed(network, properties.getInterfaceName() + ":" + addresses, false);
            }
            private void changed(Network network, String link, boolean lost) {
                synchronized (wifiNetworks) {
                    if (!running) return;
                    if (lost) wifiNetworks.remove(network);
                    else if (!"available".equals(link) || !wifiNetworks.containsKey(network)) wifiNetworks.put(network, link);
                    List<String> signatures = new ArrayList<>();
                    for (Map.Entry<Network, String> item : wifiNetworks.entrySet()) {
                        signatures.add(item.getKey().getNetworkHandle() + ":" + item.getValue());
                    }
                    java.util.Collections.sort(signatures);
                    networkRecovery.observe(signatures.toString(), android.os.SystemClock.elapsedRealtime());
                }
                synchronized (networkSignal) { networkWakeRequested = true; networkSignal.notifyAll(); }
            }
        };
        try {
            // A local-only Wi-Fi network must count even before internet validation succeeds.
            connectivity.registerNetworkCallback(new NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback);
            networkCallback = callback;
        } catch (RuntimeException error) {
            BridgeLog.error("vowlan_network_observer_failed_polling_retained", error);
        }
    }

    private synchronized void invalidateAdvertisementForNetworkChange() {
        NsdManager.RegistrationListener previous = advertisement;
        // Retire identity before unregistering: an old registration success can arrive late.
        advertisement = null;
        advertisementEpoch.invalidate();
        advertisementRetryAt = 0;
        NsdManager manager = getSystemService(NsdManager.class);
        if (previous != null && manager != null) {
            try { manager.unregisterService(previous); } catch (RuntimeException ignored) {}
        }
    }

    private void waitForNetworkCycle(long delayMillis) throws InterruptedException {
        synchronized (networkSignal) {
            if (!networkWakeRequested && running) networkSignal.wait(delayMillis);
            networkWakeRequested = false;
        }
    }

    private synchronized void ensureStarted(Inet4Address hotspot, Inet4Address avf) throws Exception {
        if (!running) return;
        String host = hotspot.getHostAddress();
        if (host.equals(activeHotspot) && control != null && control.localPort() > 0
                && pcm != null && pcm.localPort() > 0) { retryAdvertisement(); return; }
        stopPrimaryGateway();
        VoWLANControlGateway nextControl = new VoWLANControlGateway(this);
        VoWLANPCMRelay nextPCM = new VoWLANPCMRelay(this);
        nextControl.start(hotspot, CONTROL_PORT);
        try {
            nextPCM.start(hotspot, PCM_PORT, new InetSocketAddress(avf, 7580));
        } catch (Exception error) {
            nextControl.close();
            throw error;
        }
        control = nextControl;
        pcm = nextPCM;
        activeHotspot = host;
        DIRECT_ROUTES.put(host, control.localPort(), pcm.localPort());
        activeControlPort = control.localPort();
        activePcmPort = pcm.localPort();
        if (control.localPort() != CONTROL_PORT || pcm.localPort() != PCM_PORT) {
            BridgeLog.info("vowlan_preferred_port_occupied control_port=" + control.localPort()
                    + " pcm_port=" + pcm.localPort());
        }
        retryAdvertisement();
        BridgeLog.info("vowlan_ready hotspot=" + host + " control_port=" + control.localPort()
                + " pcm_port=" + pcm.localPort());
    }

    private void advertise() {
        long epoch = advertisementEpoch.begin();
        NsdServiceInfo info = new NsdServiceInfo();
        String agentID = AndroidAgentIdentity.agentID(this);
        String kind = RuntimeMode.isStandalone(this) ? "standalone" : "avf";
        info.setServiceName("AirSIM-" + kind + "-" + agentID.substring(Math.max(0, agentID.length() - 8)));
        info.setServiceType("_airsim-vowlan._tcp.");
        info.setPort(control.localPort());
        info.setAttribute("v", "1");
        info.setAttribute("agent_id", agentID);
        info.setAttribute("agent_kind", kind);
        info.setAttribute("device_name", AndroidAgentIdentity.deviceName());
        info.setAttribute("manufacturer", android.os.Build.MANUFACTURER);
        info.setAttribute("model", android.os.Build.MODEL);
        info.setAttribute("host", activeHotspot);
        info.setAttribute("control_port", Integer.toString(control.localPort()));
        info.setAttribute("pcm_port", Integer.toString(pcm.localPort()));
        info.setAttribute("caps", "control,pcm");
        advertisement = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo ignored) {
                advertisementEpoch.completed(epoch, true);
            }
            @Override public void onRegistrationFailed(NsdServiceInfo ignored, int code) {
                advertisementEpoch.completed(epoch, false);
                BridgeLog.info("vowlan_advertisement_failed code=" + code);
            }
            @Override public void onServiceUnregistered(NsdServiceInfo ignored) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo ignored, int code) {}
        };
        getSystemService(NsdManager.class).registerService(info, NsdManager.PROTOCOL_DNS_SD, advertisement);
    }

    private void retryAdvertisement() {
        long now = android.os.SystemClock.elapsedRealtime();
        if (advertisementEpoch.isReady() || now < advertisementRetryAt) return;
        advertisementRetryAt = now + 15_000;
        advertisementEpoch.invalidate();
        NsdManager manager = getSystemService(NsdManager.class);
        if (advertisement != null && manager != null) {
            try { manager.unregisterService(advertisement); } catch (RuntimeException ignored) {}
        }
        advertisement = null;
        try { advertise(); }
        catch (RuntimeException error) { BridgeLog.error("vowlan_advertisement_failed_manual_available", error); }
    }

    private synchronized void stopPrimaryGateway() {
        advertisementEpoch.invalidate();
        if (advertisement != null) {
            try { getSystemService(NsdManager.class).unregisterService(advertisement); }
            catch (IllegalArgumentException ignored) {}
            advertisement = null;
        }
        try { if (control != null) control.close(); } catch (Exception ignored) {}
        try { if (pcm != null) pcm.close(); } catch (Exception ignored) {}
        control = null;
        pcm = null;
        advertisementRetryAt = 0;
        DIRECT_ROUTES.remove(activeHotspot);
        activeHotspot = "";
        activeControlPort = CONTROL_PORT;
        activePcmPort = PCM_PORT;
    }

    private synchronized void syncAdditionalGateways(List<Inet4Address> addresses, Inet4Address avf) throws Exception {
        if (!running) return;
        List<String> wanted = new ArrayList<>();
        for (Inet4Address address : addresses) wanted.add(address.getHostAddress());
        for (String host : new ArrayList<>(extraGateways.keySet())) {
            if (wanted.contains(host)) continue;
            ExtraGateway removed = extraGateways.remove(host);
            DirectCallOwnership.disconnectHost(host);
            DIRECT_ROUTES.remove(host);
            try { removed.control().close(); } catch (Exception ignored) {}
            try { removed.pcm().close(); } catch (Exception ignored) {}
        }
        for (Inet4Address address : addresses) {
            String host = address.getHostAddress();
            if (extraGateways.containsKey(host)) continue;
            VoWLANControlGateway nextControl = new VoWLANControlGateway(this);
            VoWLANPCMRelay nextPCM = new VoWLANPCMRelay(this);
            try {
                nextControl.start(address, CONTROL_PORT);
                nextPCM.start(address, PCM_PORT, new InetSocketAddress(avf, 7580));
            } catch (Exception error) {
                try { nextControl.close(); } catch (Exception ignored) {}
                try { nextPCM.close(); } catch (Exception ignored) {}
                throw error;
            }
            extraGateways.put(host, new ExtraGateway(nextControl, nextPCM));
            DIRECT_ROUTES.put(host, nextControl.localPort(), nextPCM.localPort());
        }
    }

    private synchronized void stopGateways() {
        stopPrimaryGateway();
        for (String host : new ArrayList<>(extraGateways.keySet())) {
            ExtraGateway removed = extraGateways.remove(host);
            DIRECT_ROUTES.remove(host);
            try { removed.control().close(); } catch (Exception ignored) {}
            try { removed.pcm().close(); } catch (Exception ignored) {}
        }
    }

    private synchronized boolean hasVoWLANCall() {
        return (control != null && control.ownsCall()) || (pcm != null && pcm.hasActiveSession())
                || extraGateways.values().stream().anyMatch(g -> g.control().ownsCall() || g.pcm().hasActiveSession());
    }

    private static List<Inet4Address> additionalAddresses() throws Exception {
        List<Inet4Address> addresses = new ArrayList<>();
        // Required for Tailscale's userspace TCP proxy; not a wildcard listener.
        addresses.add((Inet4Address) InetAddress.getByName("127.0.0.1"));
        Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
        while (interfaces.hasMoreElements()) {
            NetworkInterface item = interfaces.nextElement();
            if (!item.isUp()) continue;
            Enumeration<InetAddress> values = item.getInetAddresses();
            while (values.hasMoreElements()) {
                InetAddress value = values.nextElement();
                if (value instanceof Inet4Address ipv4
                        && VoWLANNetworkPolicy.isOverlayInterface(item.getName(), ipv4.getHostAddress())) addresses.add(ipv4);
            }
        }
        return addresses;
    }

    private void diagnosticState(Inet4Address hotspot, Inet4Address avf, boolean paired,
                                 boolean agentReady, boolean pcmReady, boolean dialerRoleHeld) {
        String value = "hotspot=" + address(hotspot) + " avf=" + address(avf) + " paired=" + paired
                + " agent_ready=" + agentReady + " pcm_ready=" + pcmReady
                + " dialer_role=" + dialerRoleHeld;
        currentDiagnosticState = value;
        if (!value.equals(lastDiagnosticState)) {
            lastDiagnosticState = value;
            BridgeLog.info("vowlan_state " + value);
        }
    }

    private static String address(InetAddress address) {
        return address == null ? "missing" : address.getHostAddress();
    }

    private static Inet4Address findAddress(boolean hotspot) throws Exception {
        Inet4Address wifiFallback = null;
        Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
        while (interfaces.hasMoreElements()) {
            NetworkInterface item = interfaces.nextElement();
            if (!item.isUp() || item.isLoopback()) continue;
            Enumeration<InetAddress> addresses = item.getInetAddresses();
            while (addresses.hasMoreElements()) {
                InetAddress address = addresses.nextElement();
                if (!(address instanceof Inet4Address value)) continue;
                if (hotspot && VoWLANNetworkPolicy.isHotspotInterface(item.getName(), value.getHostAddress())) return value;
                if (hotspot && wifiFallback == null
                        && VoWLANNetworkPolicy.isVoWLANInterface(item.getName(), value.getHostAddress())) {
                    wifiFallback = value;
                }
                if (!hotspot && "avf_tap_fixed".equals(item.getName())) return value;
            }
        }
        return hotspot ? wifiFallback : null;
    }

    private static boolean portOpen(InetAddress address, int port) {
        try (Socket socket = new Socket()) {
            socket.connect(new InetSocketAddress(address, port), 500);
            return true;
        } catch (Exception error) {
            BridgeLog.debug("pcm_probe_failed address=" + address.getHostAddress() + " port=" + port
                    + " error=" + error.getClass().getSimpleName());
            return false;
        }
    }

    private void update(String detail) {
        long now = System.currentTimeMillis();
        if (!notificationGate.shouldPublish(detail, now)) return;
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.VOWLAN_ID, BridgeNotification.vowlan(this, detail));
        notificationGate.published(detail, now);
    }

    @Override public void onDestroy() {
        BridgeLog.info("vowlan_service_destroyed");
        currentDiagnosticState = "服务已停止";
        running = false;
        networkRecovery.close();
        if (connectivity != null && networkCallback != null) {
            try { connectivity.unregisterNetworkCallback(networkCallback); } catch (RuntimeException ignored) {}
        }
        networkCallback = null;
        synchronized (networkSignal) { networkSignal.notifyAll(); }
        worker.shutdownNow();
        stopGateways();
        super.onDestroy();
    }
}
