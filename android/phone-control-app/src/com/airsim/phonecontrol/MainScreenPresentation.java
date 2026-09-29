package com.airsim.phonecontrol;

public final class MainScreenPresentation {
    private MainScreenPresentation() {}

    public static String formatPairingCode(String code) {
        if (code == null) return "--- ---";
        String digits = code.replaceAll("[^0-9]", "");
        if (digits.length() != 6) return "--- ---";
        return digits.substring(0, 3) + " " + digits.substring(3);
    }

    public static String recentLogLines(String log, String filter, int maximum) {
        if (log == null || log.isBlank() || maximum <= 0) return "暂无 Debug 日志";
        String category = filter == null ? "" : filter.trim();
        String[] lines = log.split("\\R");
        StringBuilder visible = new StringBuilder();
        int count = 0;
        for (int index = lines.length - 1; index >= 0 && count < maximum; index--) {
            String line = lines[index].trim();
            if (line.isEmpty()) continue;
            if (!category.isEmpty() && !"全部".equals(category)
                    && !line.toLowerCase(java.util.Locale.ROOT)
                    .contains(category.toLowerCase(java.util.Locale.ROOT))) continue;
            if (visible.length() > 0) visible.append('\n');
            visible.append(line);
            count++;
        }
        return visible.length() == 0 ? "此分类暂无日志" : visible.toString();
    }

    public static String activitySummary(String line) {
        if (line == null || line.isBlank()) return "系统状态已更新";
        String value = line.toLowerCase(java.util.Locale.ROOT);
        if (value.contains("pairing_completed")) return "VoWLAN 配对完成";
        if (value.contains("pairing_started")) return "等待 iPhone 配对";
        if (value.contains("watchdog_created")) return "Agent 守护服务已启动";
        if (value.contains("watchdog_configuration_available")) return "Linux Agent 配置已载入";
        if (value.contains("application_started")) return "应用服务已启动";
        if (value.contains("shizuku_user_service_connected")) return "Shizuku PCM 桥已连接";
        if (value.contains("shizuku_binder_received")) return "Shizuku 已连接";
        if (value.contains("shizuku_permission_granted")) return "Shizuku 权限已授予";
        if (value.contains("vowlan_service_created")) return "VoWLAN 服务已启动";
        if (value.contains("vowlan_service_start_requested")) return "VoWLAN 服务启动中";
        if (value.contains("vowlan_ready")) return "VoWLAN 局域网服务已就绪";
        if (value.contains("vowlan_state") && value.contains("pcm_ready=true")) {
            return "VoWLAN 健康检查通过";
        }
        if (value.contains("http_request_finished") && value.contains("status=200")
                && value.contains("/api/android/status")) {
            return "Linux Agent 健康检查通过";
        }
        if (value.contains("telecom_call_added")) return "系统通话已接入";
        if (value.contains("telecom_call_removed")) return "系统通话已结束";
        if (value.contains("command_result") && value.contains("success=true")) {
            return "Android 指令执行成功";
        }
        if (value.contains("failed") || value.contains("error")) return "连接异常，已记录诊断";
        return "系统状态已更新";
    }
}
