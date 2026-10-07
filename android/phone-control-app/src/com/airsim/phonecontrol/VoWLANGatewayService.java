package com.airsim.phonecontrol;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.app.role.RoleManager;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.IBinder;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.util.Enumeration;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class VoWLANGatewayService extends Service {
    public static final int CONTROL_PORT = 7590;
    public static final int PCM_PORT = 7591;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile boolean running;
    private VoWLANControlGateway control;
    private VoWLANPCMRelay pcm;
    private NsdManager.RegistrationListener advertisement;
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
        worker.execute(this::lifecycleLoop);
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) { return START_STICKY; }
    @Override public IBinder onBind(Intent intent) { return null; }

    private void lifecycleLoop() {
        while (running) {
            try {
                Inet4Address hotspot = findAddress(true);
                Inet4Address avf = findAddress(false);
                if (hotspot == null && hasVoWLANCall()) {
                    BridgeLog.info("hotspot_lost_no_midcall_handover action=end_current_call");
                    CallRepository.disconnectAll();
                }
                boolean paired = VoWLANPairingStore.configured(this);
                RoleManager roleManager = getSystemService(RoleManager.class);
                boolean dialerRoleHeld = roleManager != null
                        && roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)
                        && roleManager.isRoleHeld(RoleManager.ROLE_DIALER);
                boolean agentReady = false;
                boolean pcmReady = false;
                if (hotspot != null && avf != null && paired && AppConfig.configured(this)) {
                    boolean sameRunningGateway = hotspot.getHostAddress().equals(activeHotspot)
                            && control != null && pcm != null;
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
                        hotspot != null, paired, agentReady, pcmReady, dialerRoleHeld)) {
                    ensureStarted(hotspot, avf);
                    update("VoWLAN 就绪 · " + hotspot.getHostAddress());
                } else {
                    stopGateways();
                    update(!dialerRoleHeld ? "请将 AirSIM 设为默认电话应用"
                            : !paired ? "VoWLAN 未配对"
                            : hotspot == null ? "正在等待同网 Wi-Fi 或三星热点"
                            : !agentReady ? "Linux Agent 尚未就绪" : "PCM 音频桥尚未就绪");
                }
                Thread.sleep(5_000);
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

    private synchronized void ensureStarted(Inet4Address hotspot, Inet4Address avf) throws Exception {
        String host = hotspot.getHostAddress();
        if (host.equals(activeHotspot) && control != null && pcm != null && advertisement != null) return;
        stopGateways();
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
        advertise();
        BridgeLog.info("vowlan_ready hotspot=" + host + " control_port=" + CONTROL_PORT + " pcm_port=" + PCM_PORT);
    }

    private void advertise() {
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("AirSIM-Samsung-VoWLAN");
        info.setServiceType("_airsim-vowlan._tcp.");
        info.setPort(CONTROL_PORT);
        info.setAttribute("v", "1");
        info.setAttribute("device", "samsung-phone");
        info.setAttribute("host", activeHotspot);
        info.setAttribute("control_port", Integer.toString(CONTROL_PORT));
        info.setAttribute("pcm_port", Integer.toString(PCM_PORT));
        info.setAttribute("caps", "control,pcm");
        advertisement = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo ignored) {}
            @Override public void onRegistrationFailed(NsdServiceInfo ignored, int code) {
                BridgeLog.info("vowlan_advertisement_failed code=" + code);
            }
            @Override public void onServiceUnregistered(NsdServiceInfo ignored) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo ignored, int code) {}
        };
        getSystemService(NsdManager.class).registerService(info, NsdManager.PROTOCOL_DNS_SD, advertisement);
    }

    private synchronized void stopGateways() {
        if (advertisement != null) {
            try { getSystemService(NsdManager.class).unregisterService(advertisement); }
            catch (IllegalArgumentException ignored) {}
            advertisement = null;
        }
        try { if (control != null) control.close(); } catch (Exception ignored) {}
        try { if (pcm != null) pcm.close(); } catch (Exception ignored) {}
        control = null;
        pcm = null;
        activeHotspot = "";
    }

    private synchronized boolean hasVoWLANCall() {
        return (control != null && control.ownsCall()) || (pcm != null && pcm.hasActiveSession());
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
        getSystemService(android.app.NotificationManager.class).notify(
                BridgeNotification.VOWLAN_ID, BridgeNotification.vowlan(this, detail));
    }

    @Override public void onDestroy() {
        BridgeLog.info("vowlan_service_destroyed");
        currentDiagnosticState = "服务已停止";
        running = false;
        worker.shutdownNow();
        stopGateways();
        super.onDestroy();
    }
}
