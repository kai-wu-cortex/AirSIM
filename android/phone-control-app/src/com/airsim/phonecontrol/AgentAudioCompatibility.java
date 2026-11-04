package com.airsim.phonecontrol;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Presentation policy for bounded privileged evidence. No audio, network or device actions. */
final class AgentAudioCompatibility {
    enum Level { PENDING, ATTENTION, INCOMPATIBLE, OBSERVED }
    record Result(Level level, String title, List<String> points) {
        String details() { return "• " + String.join("\n• ", points); }
    }

    static Result evaluate(String report, boolean carrierActive) {
        Map<String, String> fields = parse(report);
        List<String> points = new ArrayList<>();
        if ("timeout".equals(fields.get("privileged_startup"))) {
            return result(Level.ATTENTION, "Shizuku 用户服务未启动 · 尚未进入音频检测",
                "Shizuku 主服务在线不代表 AirSIM 的特权服务已启动；当前没有可用于验证双向 PCM 的服务连接。",
                "true".equals(fields.get("shizuku_mtk_startup_risk"))
                    ? "检测到联发科平台与 Shizuku 13.6.0：上游存在应用上下文初始化失败问题。可使用已授权的 Root 通道，或改用官方兼容版本并重新授权。"
                    : "请检查 Shizuku 授权与用户服务启动日志；可以手动重试，或使用已授权的 Root 通道。",
                "启动超时不等于音频硬件不兼容。服务启动后，还需分别验证通话下行采集和上行注入。");
        }
        if (fields.isEmpty()) return result(Level.PENDING, "等待音频桥检测",
            "请确认 Shizuku / Root 已运行并授权 AirSIM，等待用户服务返回最新状态。",
            "未取得检测数据不代表设备不兼容。Agent 在线也不等于双向通话正常。");
        String tx = fields.getOrDefault("pcm_cap_tx", "unknown");
        if ("ok".equals(fields.get("pcm_cap_query")) && "missing".equals(tx)) {
            return result(Level.INCOMPATIBLE, "当前设备暂不兼容 AirSIM · 需要适配",
                "待适配：通话音频上行注入。特权查询未发现 Telephony Tx，也没有三星 VOICE_TX 接口。",
                "配对与短信不受此检测限制；需要为当前系统提供可用的通话发送后端。");
        }
        if (!"running".equals(fields.get("pcm"))) return result(Level.ATTENTION, "PCM 音频桥尚未运行",
            "先检查权限通道、用户服务和本机 PCM 监听启动情况。", "进程未启动不能直接判断为芯片不兼容。");

        String failure = fields.getOrDefault("pcm_failure", "none");
        if (!failure.equals("none")) {
            String code = fields.getOrDefault("pcm_error_code", "unknown");
            if (code.equals("permission_denied")) return result(Level.ATTENTION, "通话音频权限被系统拒绝",
                "检查 Shizuku / Root 授权与系统通话音频采集权限；普通麦克风权限不能代替通话采集权限。",
                "若授权后仍被系统拒绝，需要适配当前 ROM 的特权音频访问路径。");
            if (code.equals("telephony_tx_unavailable") || code.equals("platform_api_unavailable")) {
                return result(Level.INCOMPATIBLE, "当前设备暂不兼容 AirSIM · 需要适配",
                    code.equals("telephony_tx_unavailable") ? "待适配：通话上行注入后端，系统未提供现有桥可用的发送端口。"
                        : "待适配：当前 Android / 厂商系统缺失的音频接口。",
                    "这是最近一次音频会话的失败，重新检测或成功建立新会话后更新。");
            }
            points.add(failurePoint(code, failure));
            points.add("这是最近一次会话的故障记录；需要结合权限、通话状态和设备路由判断，不能只按芯片型号定性。");
            return new Result(Level.ATTENTION, "音频桥异常 · 待排查或适配", List.copyOf(points));
        }
        if (!"ok".equals(fields.get("pcm_cap_query"))) {
            points.add("音频端口能力尚未取得：检查特权查询权限或更新音频桥；不将查询失败当作端口缺失。");
        } else {
            points.add(tx.equals("samsung_tag") ? "发现三星 VOICE_TX 接口；接口存在不代表实际路由已验证。"
                : "发现系统通话发送端口 Telephony Tx。");
            if ("conversion".equals(fields.get("pcm_cap_format"))) points.add(
                "redmi9_mtk_experimental".equals(fields.get("pcm_profile"))
                    ? "已启用 Redmi 9 试验性格式适配，网络协议仍为 8 kHz 单声道；以实际双向听音验收为准。"
                    : "格式待验证：发送端口声明的格式与桥的 8 kHz 单声道 PCM16 不同，可能需要采样率 / 声道适配；系统也可能自动转换。");
            if ("not_exposed".equals(fields.get("pcm_cap_rx"))) points.add(
                "下行待验证：系统未公开通话接收端口，仍需验证 VOICE_DOWNLINK 采集，不能据此判定无下行。");
        }
        if (!"true".equals(fields.get("pcm_initialized"))) {
            points.add("当前没有初始化中的远程音频会话。空闲、尚未配对或仅本机通话时不会主动采集声音。");
            points.add("双向通话待验证：配对后手动进行一次通话，检测会自动观察实际数据与路由。");
            return new Result(Level.PENDING, "ok".equals(fields.get("pcm_cap_query"))
                ? "基础检查完成 · 双向通话待验证" : "检测信息不完整 · 双向通话待验证", List.copyOf(points));
        }
        if (!carrierActive) {
            points.add("等待运营商通话接通；暂不将无音频或单向接收判为故障。");
            return new Result(Level.PENDING, "等待通话音频验证", List.copyOf(points));
        }
        if ("yes".equals(fields.get("pcm_capture_silenced"))) {
            points.add("系统正在静音通话采集：检查通话录音占用、特权采集权限与 ROM 音频策略；网络传输正常也可能只收到静音数据。");
            return new Result(Level.ATTENTION, "通话下行被系统静音", List.copyOf(points));
        }
        if ("other".equals(fields.get("pcm_capture_route"))) {
            points.add("待适配：下行实际输入不是通话接收端口，不应以手机麦克风或外放回录代替通话声音。");
            return new Result(Level.ATTENTION, "通话下行路由异常", List.copyOf(points));
        }
        if ("other".equals(fields.get("pcm_route_observed")) && !tx.equals("samsung_tag")) {
            points.add("待适配：上行实际播放设备不是通话发送端口，远端声音可能未注入蜂窝通话。请结束测试并检查系统路由适配。");
            return new Result(Level.ATTENTION, "通话上行路由异常 · 需要适配", List.copyOf(points));
        }
        if (number(fields, "pcm_session_age_ms") < 0) {
            points.add("当前音频桥未返回会话时效信息，请更新并重新连接权限服务；不使用旧统计判断当前通话。");
            return new Result(Level.PENDING, "音频桥检测信息待更新", List.copyOf(points));
        }
        if (number(fields, "pcm_session_age_ms") < 10_000) {
            points.add("音频会话刚建立，正在等待双向帧与发送端路由证据。");
            return new Result(Level.PENDING, "正在验证双向 PCM 链路", List.copyOf(points));
        }
        if (number(fields, "pcm_stats_age_ms") < 0 || number(fields, "pcm_stats_age_ms") > 4_000) {
            points.add("PCM 统计未更新，不能判断双向数据是否仍在传输；检查音频桥线程与当前连接。");
            return new Result(Level.ATTENTION, "音频链路检测数据已过期", List.copyOf(points));
        }
        boolean downStalled = number(fields, "pcm_down_bytes") <= 0 || number(fields, "pcm_down_idle_ms") >= 8_000;
        boolean upStalled = number(fields, "pcm_up_bytes") <= 0 || number(fields, "pcm_up_idle_ms") >= 8_000;
        if (downStalled) points.add("下行未推进：检查 VOICE_DOWNLINK 采集、系统读取错误及手机到 iPhone 的媒体链路。");
        if (upStalled) points.add("上行未推进：检查 iPhone 音频会话、网络 / 蓝牙传输及 Telephony Tx 写入；不能直接归因为芯片不兼容。");
        if (downStalled || upStalled) return new Result(Level.ATTENTION, "双向 PCM 链路异常", List.copyOf(points));
        if (!"verified".equals(fields.get("pcm_route"))) {
            points.add("双向数据在传输，但上行路由尚未验证；需要检查 Telephony Tx / 厂商路由适配。隐藏路由需人工确认对端声音。");
            return new Result(Level.ATTENTION, "上行通话路由待验证", List.copyOf(points));
        }
        if ("redmi9_mtk_experimental".equals(fields.get("pcm_profile"))
                && !"telephony".equals(fields.get("pcm_capture_route"))) {
            points.add("Redmi 9 试验性适配尚未确认实际下行路由；不能把初始化成功视为 iPhone 已能听到声音。");
            return new Result(Level.PENDING, "Redmi 9 下行路由待验证", List.copyOf(points));
        }
        if (number(fields, "pcm_down_peak") <= 1 || number(fields, "pcm_up_peak") <= 1) {
            points.add("双向数据和发送端路由已观察到，但有一侧尚未观察到明显声音。静音、无人说话也会如此；请双方轮流讲话验证。");
            return new Result(Level.PENDING, "音频内容待人工验证", List.copyOf(points));
        }
        points.add("已观察到双向 PCM 数据推进及通话发送端路由；仍需确认双方实际能听到声音，不代表所有通话场景已适配。");
        return new Result(Level.OBSERVED, "已观察到双向 PCM 链路", List.copyOf(points));
    }

    static boolean knownShizukuMtkStartupRisk(String hardware, String version) {
        if (hardware == null || version == null) return false;
        return hardware.toLowerCase(java.util.Locale.ROOT).matches("mt[0-9]+[a-z0-9_]*")
            && (version.equals("13.6.0") || version.startsWith("13.6.0."));
    }

    private static String failurePoint(String code, String event) {
        if (code.startsWith("capture_") || event.equals("downlink_error")) return "待排查 / 适配：通话下行采集源、采样格式及系统 AudioRecord 读取。";
        if (code.startsWith("playback_") || code.equals("telephony_tx_rejected") || event.equals("uplink_error"))
            return "待排查 / 适配：Telephony Tx 上行注入、采样率 / 声道转换及 AudioTrack 写入。";
        if (code.startsWith("telephony_query")) return "待排查 / 适配：特权音频端口查询接口及访问权限。";
        if (code.startsWith("handshake")) return "待排查：PCM 握手或连接中断；检查权限服务和传输链路，不直接判定为音频硬件不兼容。";
        return "待排查：音频初始化或媒体会话失败，请查看本地 PCM 详情中的错误阶段。";
    }
    private static Result result(Level level, String title, String... points) { return new Result(level, title, List.of(points)); }
    private static Map<String, String> parse(String report) {
        Map<String, String> result = new HashMap<>();
        if (report == null || report.length() > 8192) return result;
        for (String field : report.split("\\s+")) {
            int at = field.indexOf('=');
            if (at > 0 && at < field.length() - 1) result.put(field.substring(0, at), field.substring(at + 1));
        }
        return result;
    }
    private static long number(Map<String, String> fields, String key) {
        try { return Long.parseLong(fields.get(key)); } catch (NumberFormatException ignored) { return -1; }
    }
}
