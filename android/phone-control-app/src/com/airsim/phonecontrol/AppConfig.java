package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Enumeration;

public final class AppConfig {
    public static final String DEFAULT_ENDPOINT = "http://10.185.5.25:7575";
    public static final String MODE_REMOTE_SILENT = "remote_silent";
    public static final String MODE_LOCAL_AND_PUSH = "local_and_push";
    private static final String FILE = "control";

    private AppConfig() {}

    public static String endpoint(Context context) {
		String discovered = discoverAVFEndpoint();
		if (!discovered.isEmpty()) {
            BridgeLog.debug("agent_endpoint_discovered source=avf endpoint=" + discovered);
            return discovered;
        }
        String fallback = preferences(context).getString("endpoint", DEFAULT_ENDPOINT);
        BridgeLog.debug("agent_endpoint_selected source=saved endpoint=" + fallback);
        return fallback;
    }

    public static String token(Context context) {
        return preferences(context).getString("token", "");
    }

    public static String mode(Context context) {
        return preferences(context).getString("mode", MODE_REMOTE_SILENT);
    }

    public static boolean configured(Context context) {
        return !token(context).isEmpty();
    }

    public static boolean debugEnabled(Context context) {
        return preferences(context).getBoolean("debug_enabled", true);
    }

    public static void setDebugEnabled(Context context, boolean enabled) {
        preferences(context).edit().putBoolean("debug_enabled", enabled).apply();
    }

    public static void save(Context context, String endpoint, String token, String mode) {
        String normalizedEndpoint = endpoint == null ? "" : endpoint.trim();
        if (!AVFNetworkPolicy.isAgentEndpoint(normalizedEndpoint)) {
            throw new IllegalArgumentException("Agent 必须使用 AVF 私网 HTTP 地址");
        }
		while (normalizedEndpoint.endsWith("/")) normalizedEndpoint = normalizedEndpoint.substring(0, normalizedEndpoint.length() - 1);
        if (token == null || token.trim().length() < 24) {
            throw new IllegalArgumentException("控制令牌至少 24 个字符");
        }
        String normalizedMode = MODE_LOCAL_AND_PUSH.equals(mode) ? MODE_LOCAL_AND_PUSH : MODE_REMOTE_SILENT;
        preferences(context).edit()
                .putString("endpoint", normalizedEndpoint)
                .putString("token", token.trim())
                .putString("mode", normalizedMode)
                .apply();
    }

    private static SharedPreferences preferences(Context context) {
        return context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

	private static String discoverAVFEndpoint() {
		try {
			NetworkInterface avf = NetworkInterface.getByName("avf_tap_fixed");
			if (avf == null || !avf.isUp()) return "";
			Enumeration<InetAddress> addresses = avf.getInetAddresses();
			while (addresses.hasMoreElements()) {
				InetAddress address = addresses.nextElement();
				if (address instanceof Inet4Address) {
					String endpoint = AVFNetworkPolicy.agentEndpoint(address.getHostAddress());
					if (!endpoint.isEmpty()) return endpoint;
				}
			}
		} catch (Exception error) {
			// VM 启动过程中接口可能短暂不存在；保留最后保存的地址作为回退。
			BridgeLog.debug("avf_endpoint_discovery_failed error=" + error.getClass().getSimpleName());
		}
		return "";
	}
}
