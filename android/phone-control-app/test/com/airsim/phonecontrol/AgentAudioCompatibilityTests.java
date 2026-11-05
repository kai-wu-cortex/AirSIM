package com.airsim.phonecontrol;

public final class AgentAudioCompatibilityTests {
    private static int checks;
    private static final String CAP = "pcm=running pcm_cap_query=ok pcm_cap_tx=telephony pcm_cap_rx=present pcm_cap_format=native";
    private static final String LIVE = CAP + " pcm_initialized=true pcm_failure=none pcm_session_age_ms=12000"
        + " pcm_stats_age_ms=100 pcm_down_idle_ms=100 pcm_up_idle_ms=100"
        + " pcm_down_bytes=32000 pcm_up_bytes=32000 pcm_down_peak=100 pcm_up_peak=100"
        + " pcm_route=verified pcm_route_observed=telephony";

    public static void main(String[] args) throws Exception {
        check(AgentAudioCompatibility.knownShizukuMtkStartupRisk("mt6768", "13.6.0.r1086.2650830c"), "Redmi observed Shizuku combination not detected");
        check(!AgentAudioCompatibility.knownShizukuMtkStartupRisk("mt6768", "13.5.4"), "compatible version mislabeled");
        check(!AgentAudioCompatibility.knownShizukuMtkStartupRisk("mt6768", "13.6.01"), "different version mislabeled");
        check(!AgentAudioCompatibility.knownShizukuMtkStartupRisk("qcom", "13.6.0"), "unverified platform mislabeled");
        check(!AgentAudioCompatibility.knownShizukuMtkStartupRisk(null, null), "missing version is not evidence");
        expect("privileged_startup=timeout shizuku_mtk_startup_risk=true", false,
            AgentAudioCompatibility.Level.ATTENTION, "尚未进入音频检测");
        check(AgentAudioCompatibility.evaluate("privileged_startup=timeout shizuku_mtk_startup_risk=true", false).details().contains("上游存在"), "known upstream risk omitted");
        check(!AgentAudioCompatibility.evaluate("privileged_startup=timeout shizuku_mtk_startup_risk=false", false).details().contains("13.6.0"), "unknown timeout incorrectly attributed to MTK");
        expect("", false, AgentAudioCompatibility.Level.PENDING, "等待");
        expect(CAP + " pcm_initialized=false", false, AgentAudioCompatibility.Level.PENDING, "待验证");
        expect(CAP.replace("native", "conversion") + " pcm_initialized=false", false,
            AgentAudioCompatibility.Level.PENDING, "待验证");
        check(AgentAudioCompatibility.evaluate(CAP.replace("native", "conversion"), false).details().contains("系统也可能自动转换"),
            "declared-format mismatch must not be presented as proven incompatibility");
        expect("pcm=running pcm_cap_query=unavailable pcm_cap_tx=unknown", false,
            AgentAudioCompatibility.Level.PENDING, "待验证");
        expect(CAP.replace("telephony", "missing"), false, AgentAudioCompatibility.Level.INCOMPATIBLE, "需要适配");
        expect("pcm=stopped", false, AgentAudioCompatibility.Level.ATTENTION, "尚未运行");
        expect(CAP + " pcm_failure=session_error pcm_error_code=permission_denied", false,
            AgentAudioCompatibility.Level.ATTENTION, "权限");
        expect(CAP + " pcm_failure=session_error pcm_error_code=telephony_tx_unavailable", false,
            AgentAudioCompatibility.Level.INCOMPATIBLE, "需要适配");
        expect(CAP + " pcm_failure=session_error pcm_error_code=handshake_failed", false,
            AgentAudioCompatibility.Level.ATTENTION, "待排查");
        expect(LIVE, true, AgentAudioCompatibility.Level.OBSERVED, "已观察到");
        expect(LIVE + " pcm_profile=redmi9_mtk_experimental pcm_capture_route=unknown", true,
            AgentAudioCompatibility.Level.PENDING, "下行路由待验证");
        expect(LIVE + " pcm_capture_route=other", true, AgentAudioCompatibility.Level.ATTENTION, "下行路由异常");
        expect(LIVE + " pcm_capture_silenced=yes", true, AgentAudioCompatibility.Level.ATTENTION, "系统静音");
        expect(LIVE, false, AgentAudioCompatibility.Level.PENDING, "等待通话");
        expect(LIVE.replace("age_ms=12000", "age_ms=1000"), true,
            AgentAudioCompatibility.Level.PENDING, "正在验证");
        expect(LIVE.replace("stats_age_ms=100", "stats_age_ms=5000"), true,
            AgentAudioCompatibility.Level.ATTENTION, "过期");
        expect(LIVE.replace("up_idle_ms=100", "up_idle_ms=8000"), true,
            AgentAudioCompatibility.Level.ATTENTION, "链路异常");
        String stalled = LIVE.replace("down_idle_ms=100", "down_idle_ms=9000");
        check(AgentAudioCompatibility.evaluate(stalled, true).details().contains("下行未推进"), "missing downstream diagnosis");
        expect(LIVE.replace("pcm_route_observed=telephony", "pcm_route_observed=other"), true,
            AgentAudioCompatibility.Level.ATTENTION, "路由异常");
        expect(LIVE.replace("pcm_route=verified", "pcm_route=unverified"), true,
            AgentAudioCompatibility.Level.ATTENTION, "路由待验证");
        String samsungHidden = LIVE.replace("pcm_cap_tx=telephony", "pcm_cap_tx=samsung_tag")
            .replace("pcm_route_observed=telephony", "pcm_route_observed=other").replace("pcm_route=verified", "pcm_route=unverified");
        expect(samsungHidden, true, AgentAudioCompatibility.Level.ATTENTION, "路由待验证");
        expect(LIVE.replace("down_peak=100", "down_peak=0"), true,
            AgentAudioCompatibility.Level.PENDING, "人工验证");
        check(!AgentAudioCompatibility.evaluate(LIVE + " token=private number=12345678901", true).details().contains("12345678901"),
            "raw private report data must not enter UI");
        cacheIsBoundedToConnectionAndTime();
        evidenceFlowsIntoPresentation();
        System.out.println("PASS AgentAudioCompatibilityTests checks=" + checks);
    }
    private static void cacheIsBoundedToConnectionAndTime() {
        AudioHealthReportCache cache = new AudioHealthReportCache();
        check(cache.current(1, 0).isEmpty(), "empty cache");
        cache.update(LIVE, 1, 100);
        check(cache.current(1, 5100).equals(LIVE), "fresh evidence lost");
        check(cache.current(1, 5101).isEmpty(), "stale evidence shown as healthy");
        check(cache.current(1, 99).isEmpty(), "clock rollback reused evidence");
        check(cache.current(2, 200).isEmpty(), "previous connection report reused");
        cache.clear();
        check(cache.current(1, 200).isEmpty(), "failed status refresh retained evidence");
        PrivilegedBridgeCoordinator coordinator = new PrivilegedBridgeCoordinator();
        long generation = coordinator.connectionGeneration();
        coordinator.disconnect();
        check(coordinator.connectionGeneration() != generation, "disconnect must invalidate cached reports");
    }
    private static void evidenceFlowsIntoPresentation() {
        long[] clock = {0};
        PCMHealthEvidence health = new PCMHealthEvidence(() -> clock[0]);
        health.observe("{\"event\":\"bridge_listening\"}");
        health.observe("{\"event\":\"audio_capabilities\",\"capability_query\":\"ok\",\"tx_route\":\"telephony\",\"rx_route\":\"present\",\"tx_format\":\"conversion\"}");
        health.observe("{\"event\":\"audio_initializing\"}");
        health.observe("{\"event\":\"client_ready\"}");
        health.observe("{\"event\":\"voice_tx_route_verified\"}");
        health.observe("{\"event\":\"capture_route_observed\",\"capture_route\":\"telephony\",\"capture_silenced\":\"no\"}");
        check(health.snapshot().contains("pcm_capture_route=telephony") && health.snapshot().contains("pcm_capture_silenced=no"), "capture evidence missing");
        clock[0] = 12000;
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":32000,\"uplink_bytes\":32000,\"downlink_peak\":100,\"uplink_peak\":100}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.OBSERVED, "已观察到");
        health.observe("{\"event\":\"voice_tx_route_observed\",\"route_kind\":\"other\"}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.ATTENTION, "路由异常");
        check(health.snapshot().contains("pcm_route=unverified"), "route change retained previous verification");
        health.observe("{\"event\":\"voice_tx_route_verified\"}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.OBSERVED, "已观察到");
        health.observe("{\"event\":\"voice_tx_route_observed\",\"route_kind\":\"unknown\"}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.ATTENTION, "路由待验证");
        health.observe("{\"event\":\"voice_tx_route_verified\"}");
        clock[0] = 21000;
        health.observe("{\"event\":\"pcm_stats\",\"downlink_bytes\":64000,\"uplink_bytes\":32000}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.ATTENTION, "链路异常");
        health.observe("{\"event\":\"client_closed\"}");
        expect("pcm=running " + health.snapshot(), false, AgentAudioCompatibility.Level.PENDING, "待验证");
        health.observe("{\"event\":\"audio_initializing\"}");
        health.observe("{\"event\":\"client_ready\"}");
        expect("pcm=running " + health.snapshot(), true, AgentAudioCompatibility.Level.PENDING, "正在验证");
        check(health.snapshot().contains("pcm_route=unverified") && health.snapshot().contains("pcm_up_bytes=0"),
            "new call must not inherit the previous call's observed route or byte counters");
        health.observe("{\"event\":\"audio_capabilities\",\"capability_query\":\"secret\",\"tx_route\":\"private\"}");
        check(!health.snapshot().contains("secret") && !health.snapshot().contains("private"), "unknown capability labels leaked");
        health.reset();
        check(health.snapshot().contains("pcm_cap_query=unknown"), "process restart reused old capability evidence");
    }
    private static void expect(String report, boolean active, AgentAudioCompatibility.Level level, String title) {
        var actual = AgentAudioCompatibility.evaluate(report, active);
        check(actual.level() == level && actual.title().contains(title), "unexpected result: " + actual);
    }
    private static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
}
