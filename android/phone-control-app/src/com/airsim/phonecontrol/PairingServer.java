package com.airsim.phonecontrol;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public final class PairingServer implements Closeable {
    public interface Listener {
        void onStarted(String code, String address, long expiresAtMillis);
        void onSucceeded(String agentResponse);
        void onFailed(String message);
    }

    private static final int MAX_HEADERS = 8_192;
    private static final int MAX_BODY = 32_768;
    private final Context context;
    private final Listener listener;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private volatile ServerSocket socket;
    private volatile PairingSession session;
    private volatile NsdManager.RegistrationListener registration;

    public PairingServer(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
    }

    public void start() {
        executor.execute(() -> {
            try {
                PairingSession created = PairingSession.create(System.currentTimeMillis());
                ServerSocket server = bindPreferred(context);
                server.setReuseAddress(true);
                socket = server;
                session = created;
                try { advertise(server.getLocalPort(), created); }
                catch (RuntimeException error) { BridgeLog.error("pairing_advertisement_failed_manual_available", error); }
                String address = manualAddresses(server.getLocalPort());
                listener.onStarted(created.code(), address, created.expiresAtMillis());
                timer.schedule(() -> {
                    listener.onFailed("配对窗口已过期");
                    closeQuietly();
                }, PairingSession.LIFETIME_MILLIS, TimeUnit.MILLISECONDS);
                while (!server.isClosed() && System.currentTimeMillis() <= created.expiresAtMillis()) {
                    try (Socket peer = server.accept()) {
                        if (handle(peer, created)) break;
                    } catch (Exception error) {
                        if (server.isClosed()) break;
                        BridgeLog.info("pairing_peer_failed reason=" + error.getClass().getSimpleName());
                    }
                }
            } catch (Exception error) {
                if (socket != null && !socket.isClosed()) {
                    BridgeLog.info("pairing_server_failed reason=" + safeMessage(error));
                    listener.onFailed(safeMessage(error));
                }
            } finally {
                closeQuietly();
            }
        });
    }

    private boolean handle(Socket peer, PairingSession created) throws Exception {
        peer.setSoTimeout(8_000);
        InetAddress remote = peer.getInetAddress();
        NetworkInterface localNetwork = NetworkInterface.getByInetAddress(peer.getLocalAddress());
        if (!VoWLANNetworkPolicy.permitsPairingPeer(remote, peer.getLocalAddress(),
                localNetwork == null ? null : localNetwork.getName())) {
            BridgeLog.info("pairing_claim_rejected reason=non_private_peer"
                    + " remote_family=" + (remote instanceof java.net.Inet6Address ? "ipv6" : "ipv4")
                    + " remote_link_local=" + remote.isLinkLocalAddress()
                    + " local_link_local=" + peer.getLocalAddress().isLinkLocalAddress()
                    + " interface=" + (localNetwork == null ? "unknown" : localNetwork.getName()));
            respond(peer, 403, "{\"error\":\"private_network_required\"}");
            return false;
        }
        BufferedInputStream input = new BufferedInputStream(peer.getInputStream());
        byte[] headers = readHeaders(input);
        String headerText = new String(headers, StandardCharsets.US_ASCII);
        String[] lines = headerText.split("\\r\\n");
        if (System.currentTimeMillis() > created.expiresAtMillis()) {
            respond(peer, 410, "{\"error\":\"pairing_expired\"}");
            return true;
        }
        if (lines.length > 0 && "GET /pair/v1/info HTTP/1.1".equals(lines[0])) {
            // Same public, short-lived material as Bonjour TXT. Never reveal code or credentials.
            respond(peer, 200, new JSONObject().put("product", "airsim-pair").put("version", 1)
                    .put("session_id", created.id()).put("server_public_key", PairingCrypto.base64URL(created.publicKey()))
                    .put("expires_at", created.expiresAtMillis())
                    .put("server_time", System.currentTimeMillis()).toString());
            return false;
        }
        if (lines.length == 0 || !"POST /pair/v1/claim HTTP/1.1".equals(lines[0])) {
            BridgeLog.info("pairing_claim_rejected reason=route");
            respond(peer, 404, "{\"error\":\"not_found\"}");
            return false;
        }
        int length = contentLength(lines);
        byte[] body = readExactly(input, length);
        JSONObject claim = new JSONObject(new String(body, StandardCharsets.UTF_8));
        if (claim.optInt("version") != 1 || !created.id().equals(claim.optString("session_id"))) {
            BridgeLog.info("pairing_claim_rejected reason=session");
            respond(peer, 400, "{\"error\":\"invalid_session\"}");
            return false;
        }
        byte[] plaintext;
        try {
            plaintext = created.claim(
                    PairingCrypto.decodeBase64URL(claim.getString("client_public_key")),
                    PairingCrypto.decodeBase64URL(claim.getString("sealed_registration")),
                    System.currentTimeMillis());
        } catch (GeneralSecurityException | IllegalArgumentException error) {
            BridgeLog.info("pairing_claim_rejected reason=authentication");
            respond(peer, 401, "{\"error\":\"pairing_auth_failed\"}");
            return false;
        }
        try {
            String registrationJSON = new String(plaintext, StandardCharsets.UTF_8);
            JSONObject registration = new JSONObject(registrationJSON);
            String vowlanSecret = registration.optString("vowlan_secret", "");
            if (vowlanSecret.isEmpty()) throw new GeneralSecurityException("VoWLAN secret missing");
            registration.put("android_agent_id", AndroidAgentIdentity.agentID(context));
            registration.put("android_device_name", AndroidAgentIdentity.deviceName());
            registration.put("android_manufacturer", android.os.Build.MANUFACTURER);
            registration.put("android_model", android.os.Build.MODEL);
            registration.put("android_phone_number", AndroidAgentIdentity.phoneNumber(context));
            registration.put("android_agent_kind", RuntimeMode.isStandalone(context) ? "standalone" : "avf");
            // VoWLAN HMAC 密钥只属于 Android 热点网关。Linux Agent 的 Push
            // 注册结构使用严格 JSON 解码，且无须接触该密钥，因此转发前必须移除。
            registration.remove("vowlan_secret");
            String agentResponse = new AgentClient(context).registerPairing(registration.toString());
            JSONObject response = new JSONObject(agentResponse)
                    .put("agent_id", AndroidAgentIdentity.agentID(context));
            VoWLANPairingStore.saveEncoded(context, vowlanSecret);
            BridgeLog.info("vowlan_pairing_client_saved clients="
                    + VoWLANPairingStore.records(context).size());
            VoWLANGatewayService.start(context);
            if (claim.optBoolean("want_direct_route", false)) {
                // Return the live gateway on this exact pairing interface, never guessed ports.
                DirectGatewayRoutes.Ports ports = awaitDirectRoute(peer.getLocalAddress().getHostAddress());
                if (ports == null) {
                    // Registration/key persistence succeeded, but manual pairing is not
                    // usable without authenticated control + PCM ports. Keep the 200
                    // registration response for existing iOS clients, which already
                    // reject missing route proofs as directGatewayUnavailable. Do not
                    // tell Android's user that end-to-end pairing completed.
                    BridgeLog.info("pairing_direct_gateway_unavailable state="
                            + VoWLANGatewayService.currentDiagnosticState());
                    respond(peer, 200, response.toString());
                    listener.onFailed("密钥已保存，但直连网关未就绪，尚未完成手动配对。"
                            + "请检查默认电话应用和 Shizuku/PCM 桥，待网关就绪后重新打开配对窗口。\n"
                            + VoWLANGatewayService.currentDiagnosticState());
                    return true;
                }
                if (ports != null) {
                    byte[] secret = PairingCrypto.decodeBase64URL(vowlanSecret);
                    try {
                        String agentID = AndroidAgentIdentity.agentID(context);
                        response.put("control_port", ports.controlPort()).put("pcm_port", ports.pcmPort());
                        response.put("route_proof", DirectGatewayRoutes.proof(secret, created.id(),
                                claim.getString("client_public_key"), agentID, ports.controlPort(), ports.pcmPort()));
                    } finally { java.util.Arrays.fill(secret, (byte) 0); }
                }
            }
            respond(peer, 200, response.toString());
            listener.onSucceeded(response.toString());
            return true;
        } finally {
            java.util.Arrays.fill(plaintext, (byte) 0);
        }
    }

    /**
     * Preferred pairing port is user-configurable; a busy or restricted port
     * falls back to an ephemeral one because Bonjour/manual text advertises it.
     */
    private static ServerSocket bindPreferred(Context context) throws IOException {
        int preferred = NetworkSettings.pairingPort(context);
        if (preferred > 0) {
            try {
                ServerSocket socket = new ServerSocket();
                socket.setReuseAddress(true);
                socket.bind(new InetSocketAddress(preferred));
                BridgeLog.info("pairing_preferred_port port=" + preferred);
                return socket;
            } catch (IOException error) {
                BridgeLog.info("pairing_preferred_port_busy port=" + preferred
                        + " reason=" + error.getClass().getSimpleName());
            }
        }
        return new ServerSocket(0);
    }

    private void advertise(int port, PairingSession created) {
        NsdManager manager = context.getSystemService(NsdManager.class);
        NsdServiceInfo info = new NsdServiceInfo();
        // Android NSD 的注销是异步的；用户快速重开窗口时固定服务名可能仍被
        // 系统占用并返回 ALREADY_ACTIVE。会话短 ID 保证每个一次性窗口唯一。
        info.setServiceName("AirSIM-Samsung-" + created.id().substring(0, 8));
        info.setServiceType("_airsim-pair._tcp.");
        info.setPort(port);
        info.setAttribute("v", "1");
        info.setAttribute("session", created.id());
        info.setAttribute("key", PairingCrypto.base64URL(created.publicKey()));
        info.setAttribute("expires", Long.toString(created.expiresAtMillis()));
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo ignored) {}
            @Override public void onRegistrationFailed(NsdServiceInfo ignored, int code) {
                BridgeLog.info("pairing_advertisement_failed code=" + code);
                // Keep manual TCP pairing available even if multicast/NSD fails.
            }
            @Override public void onServiceUnregistered(NsdServiceInfo ignored) {}
            @Override public void onUnregistrationFailed(NsdServiceInfo ignored, int code) {}
        };
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    private static byte[] readHeaders(BufferedInputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        int state = 0;
        while (output.size() < MAX_HEADERS) {
            int value = input.read();
            if (value < 0) throw new IOException("请求头不完整");
            output.write(value);
            state = (state == 0 && value == '\r') ? 1
                    : (state == 1 && value == '\n') ? 2
                    : (state == 2 && value == '\r') ? 3
                    : (state == 3 && value == '\n') ? 4 : 0;
            if (state == 4) return output.toByteArray();
        }
        throw new IOException("请求头过大");
    }

    private static int contentLength(String[] lines) throws IOException {
        for (String line : lines) {
            if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) {
                int value;
                try { value = Integer.parseInt(line.substring(15).trim()); }
                catch (NumberFormatException error) { throw new IOException("Content-Length 无效", error); }
                if (value < 1 || value > MAX_BODY) throw new IOException("请求体大小无效");
                return value;
            }
        }
        throw new IOException("缺少 Content-Length");
    }

    private static byte[] readExactly(BufferedInputStream input, int length) throws IOException {
        byte[] output = new byte[length];
        int offset = 0;
        while (offset < length) {
            int count = input.read(output, offset, length - offset);
            if (count < 0) throw new IOException("请求体不完整");
            offset += count;
        }
        return output;
    }

    private static void respond(Socket peer, int status, String json) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : "Error";
        byte[] headers = ("HTTP/1.1 " + status + " " + reason + "\r\nContent-Type: application/json\r\n" +
                "Content-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII);
        OutputStream output = peer.getOutputStream();
        output.write(headers);
        output.write(body);
        output.flush();
    }

    static String preferredPrivateIPv4() throws IOException {
        List<NetworkInterface> interfaces = new ArrayList<>();
        Enumeration<NetworkInterface> enumeration = NetworkInterface.getNetworkInterfaces();
        while (enumeration.hasMoreElements()) interfaces.add(enumeration.nextElement());
        interfaces.sort(Comparator.comparingInt(item -> interfacePriority(item.getName())));
        for (NetworkInterface item : interfaces) {
            if (!item.isUp() || item.isLoopback()) continue;
            Enumeration<InetAddress> addresses = item.getInetAddresses();
            while (addresses.hasMoreElements()) {
                InetAddress address = addresses.nextElement();
                String host = address.getHostAddress();
                if (address instanceof Inet4Address && address.isSiteLocalAddress() && !host.startsWith("10.185.5.")) return host;
            }
        }
        throw new IOException("未找到 VoWLAN IPv4 地址，请连接 Wi-Fi 或开启移动热点");
    }

    private static DirectGatewayRoutes.Ports awaitDirectRoute(String localHost) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12);
        do {
            DirectGatewayRoutes.Ports ports = VoWLANGatewayService.DIRECT_ROUTES.forHost(localHost);
            if (ports != null) return ports;
            Thread.sleep(100);
        } while (System.nanoTime() < deadline);
        return null;
    }

    private static String manualAddresses(int port) throws IOException {
        List<String> values = new ArrayList<>();
        Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
        while (interfaces.hasMoreElements()) {
            NetworkInterface item = interfaces.nextElement();
            if (!item.isUp() || item.isLoopback()) continue;
            Enumeration<InetAddress> addresses = item.getInetAddresses();
            while (addresses.hasMoreElements()) {
                InetAddress value = addresses.nextElement();
                if (!(value instanceof Inet4Address)) continue;
                String host = value.getHostAddress();
                if (VoWLANNetworkPolicy.isVoWLANInterface(item.getName(), host)) values.add("局域网 " + host + ":" + port);
                else if (VoWLANNetworkPolicy.isCustomPrivate(host)) values.add("自定义网段 " + host + ":" + port);
                else if (VoWLANNetworkPolicy.isOverlayInterface(item.getName(), host)) values.add("VPN " + host + ":" + port);
            }
        }
        values.add("Tailscale：填写本机在 Tailscale 中的 IPv4；配对端口 " + port);
        return String.join("\n", values);
    }

    private static int interfacePriority(String name) {
        if (name.startsWith("swlan") || name.startsWith("ap")) return 0;
        if (name.startsWith("wlan")) return 1;
        return 2;
    }

    private static String safeMessage(Exception error) {
        String message = error.getMessage();
        return message == null || message.isBlank() ? error.getClass().getSimpleName() : message;
    }

    private void closeQuietly() {
        try { close(); } catch (IOException ignored) {}
    }

    @Override public void close() throws IOException {
        NsdManager.RegistrationListener active = registration;
        registration = null;
        if (active != null) {
            try { context.getSystemService(NsdManager.class).unregisterService(active); }
            catch (IllegalArgumentException ignored) {}
        }
        ServerSocket activeSocket = socket;
        if (activeSocket != null && !activeSocket.isClosed()) activeSocket.close();
        timer.shutdownNow();
        executor.shutdown();
    }
}
