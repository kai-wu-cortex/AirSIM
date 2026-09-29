package main

import (
	"bytes"
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func TestCloudPCMStartsListenerBeforeDialWithoutWaitingForClient(t *testing.T) {
	wantErr := errors.New("stop after ordering assertion")
	events := make(chan string, 2)
	_, err := establishCloudPCMConnection(
		context.Background(),
		func() error {
			events <- "listening"
			return nil
		},
		func(context.Context) (net.Conn, error) {
			events <- "dial"
			return nil, wantErr
		},
	)
	if !errors.Is(err, wantErr) {
		t.Fatalf("error=%v, want %v", err, wantErr)
	}
	if first, second := <-events, <-events; first != "listening" || second != "dial" {
		t.Fatalf("order=%q,%q, want listening,dial", first, second)
	}
}

func TestCloudPCMMilestonesAreMonotonic(t *testing.T) {
	sequence := []string{"answer_ok", "pcm_listening", "active", "pcm_ready", "pcm_first_frame"}
	if err := validateCloudPCMMilestoneOrder(sequence); err != nil {
		t.Fatal(err)
	}
	if validateCloudPCMMilestoneOrder([]string{"answer_ok", "active", "pcm_listening"}) == nil {
		t.Fatal("active before listener must be rejected")
	}
}

func TestCloudPCMMilestoneDurationsDescribeStartupBoundaries(t *testing.T) {
	started := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(started, cloudCallDescriptor{})
	health.markAnswerAcknowledged(started)
	health.markListening(started.Add(1200 * time.Millisecond))
	health.beginMedia(started.Add(1500 * time.Millisecond))
	health.observeDownlink(make([]byte, cloudPCMFrameBytes), started.Add(1900*time.Millisecond), 0)
	fields := cloudPCMMilestoneFields(health.snapshot())
	for key, want := range map[string]string{
		"answer_to_listen_ms":            "1200",
		"listen_to_handshake_ms":         "300",
		"handshake_to_first_downlink_ms": "400",
	} {
		if got := fields[key]; got != want {
			t.Fatalf("%s=%q, want %q", key, got, want)
		}
	}
}

func TestCloudPCMFrameRoundTripsSequenceTimestampAndPayload(t *testing.T) {
	payload := bytes.Repeat([]byte{0x34, 0x12}, cloudPCMFrameBytes/2)
	wire := encodeCloudPCMFrame(payload, 42, 1_800_000_000_123)

	frame, framed, err := decodeCloudPCMFrame(wire)
	if err != nil {
		t.Fatalf("解码带头 PCM 帧失败: %v", err)
	}
	if !framed {
		t.Fatal("AirSIM PCM 帧应被识别为带序号媒体帧")
	}
	if frame.Sequence != 42 || frame.TimestampMilliseconds != 1_800_000_000_123 {
		t.Fatalf("帧身份=(%d,%d)，期望 (42,1800000000123)", frame.Sequence, frame.TimestampMilliseconds)
	}
	if !bytes.Equal(frame.Payload, payload) {
		t.Fatal("PCM 负载往返后发生变化")
	}
}

func TestCloudPCMFrameDecoderKeepsLegacyRawPCMCompatible(t *testing.T) {
	payload := bytes.Repeat([]byte{0x78, 0x56}, cloudPCMFrameBytes/2)
	frame, framed, err := decodeCloudPCMFrame(payload)
	if err != nil || framed {
		t.Fatalf("旧 PCM 解码 framed=%v err=%v，期望原样兼容", framed, err)
	}
	if !bytes.Equal(frame.Payload, payload) {
		t.Fatal("旧 PCM 负载不应被修改")
	}
}

func TestCloudPCMTimeoutPolicyGivesWarmRouteOneSoftRetryBeforeRebuild(t *testing.T) {
	if got := cloudPCMRecoveryForTimeout(1); got != cloudPCMReconnectOnly {
		t.Fatalf("首次 PCM 超时恢复=%q，期望只重连本地 PCM", got)
	}
	if got := cloudPCMRecoveryForTimeout(2); got != cloudPCMRebuildVoiceRoute {
		t.Fatalf("连续第二次 PCM 超时恢复=%q，期望重建语音路由", got)
	}
}

func TestCloudPCMHealthPolicyDoesNotRestartModuleRouteForMissingRemoteUplink(t *testing.T) {
	if got := cloudPCMRecoveryForHealth(cloudMediaRebuildUplinkStalled); got != cloudPCMKeepVoiceRoute {
		t.Fatalf("远端上行停顿恢复=%q，期望保留模块语音路由", got)
	}
}

func TestFirstDownlinkTimeoutRebuildsVoiceRouteWithoutUSBReset(t *testing.T) {
	action := cloudPCMRecoveryForHealth(cloudMediaRebuildDownlinkStalled)
	if action != cloudPCMRebuildVoiceRoute {
		t.Fatalf("action=%s, want %s", action, cloudPCMRebuildVoiceRoute)
	}
	if cloudPCMRecoveryTouchesUSB(action) {
		t.Fatal("PCM recovery must not reset ECM")
	}
}

func TestCloudMediaFirstDownlinkDeadlineIsEightSeconds(t *testing.T) {
	startedAt := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	health.beginMedia(startedAt)
	if got := health.evaluate(startedAt.Add(7990 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("before deadline=%s, want healthy", got)
	}
	if got := health.evaluate(startedAt.Add(8 * time.Second)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("at deadline=%s, want %s", got, cloudMediaRebuildDownlinkStalled)
	}
}

func TestCloudPCMStatsCarryNegotiatedMediaProtocol(t *testing.T) {
	health := newCloudMediaHealthTracker(time.Unix(1_800_000_000, 0), cloudCallDescriptor{})
	health.setMediaProtocol(cloudPCMProtocolFramedV1)
	stats := cloudPCMTransmissionStatsFromHealth(health.snapshot())
	if stats.MediaProtocol != cloudPCMProtocolFramedV1 {
		t.Fatalf("媒体统计协议=%q，期望 %q", stats.MediaProtocol, cloudPCMProtocolFramedV1)
	}
}

func TestCloudMediaHealthRebuildsAfterSixSecondsAndStopsAtThree(t *testing.T) {
	startedAt := time.Unix(1_800_000_000, 0)
	tracker := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{
		CallID: "call-health", CallUUID: "49f5fa4d-b8e4-4997-bb0b-dca076997344", Generation: 4,
	})
	tracker.beginMedia(startedAt)
	tracker.observeDownlink(make([]byte, 320), startedAt, 0)
	if got := tracker.evaluate(startedAt.Add(5990 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("6 秒前健康决策=%q，期望 %q", got, cloudMediaHealthy)
	}
	for attempt := 1; attempt <= 3; attempt++ {
		now := startedAt.Add(time.Duration(attempt) * 6100 * time.Millisecond)
		if got := tracker.evaluate(now); got != cloudMediaRebuildDownlinkStalled {
			t.Fatalf("第 %d 次重建决策=%q，期望 %q", attempt, got, cloudMediaRebuildDownlinkStalled)
		}
		if !tracker.beginRebuild(cloudMediaRebuildDownlinkStalled, now) {
			t.Fatalf("第 %d 次重建应被允许", attempt)
		}
		tracker.observeDownlink(make([]byte, 320), now, 0)
	}
	if got := tracker.evaluate(startedAt.Add(24400 * time.Millisecond)); got != cloudMediaRebuildExhausted {
		t.Fatalf("预算耗尽决策=%q，期望 %q", got, cloudMediaRebuildExhausted)
	}
	if tracker.beginRebuild(cloudMediaRebuildDownlinkStalled, startedAt.Add(24400*time.Millisecond)) {
		t.Fatal("每通电话不得执行第 4 次媒体重建")
	}
	if snapshot := tracker.snapshot(); snapshot.RebuildCount != 3 {
		t.Fatalf("重建次数=%d，期望 3", snapshot.RebuildCount)
	}
}

func TestCloudMediaHealthDoesNotCountRingingAsMissingAudio(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(start, cloudCallDescriptor{})
	if got := health.evaluate(start.Add(90 * time.Second)); got != cloudMediaHealthy {
		t.Fatalf("waiting for answer must not consume media rebuild budget: %s", got)
	}
}

func TestCloudMediaHealthStartsFreshWindowAfterPCMHandshake(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(start, cloudCallDescriptor{})
	connected := start.Add(90 * time.Second)
	health.beginMedia(connected)
	if got := health.evaluate(connected.Add(7900 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("first PCM startup must have its own grace period: %s", got)
	}
	if got := health.evaluate(connected.Add(8100 * time.Millisecond)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("initial missing audio must eventually time out: %s", got)
	}
	health.observeDownlink(make([]byte, 320), connected.Add(22*time.Second), 0)
	health.observeUplink(make([]byte, 320), connected.Add(22*time.Second))
	if got := health.evaluate(connected.Add(27 * time.Second)); got != cloudMediaHealthy {
		t.Fatalf("short active-call gap must not rebuild: %s", got)
	}
	if got := health.evaluate(connected.Add(29 * time.Second)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("active call must detect real interruption: %s", got)
	}
	health.beginRebuild(cloudMediaRebuildDownlinkStalled, connected.Add(29*time.Second))
	health.beginMedia(connected.Add(30 * time.Second))
	if health.snapshot().RebuildCount != 1 {
		t.Fatal("reconnect erased the per-call budget")
	}
}

func TestCloudMediaHealthTreatsValidSilenceAsHealthyAndDetectsStalledUplink(t *testing.T) {
	startedAt := time.Unix(1_800_000_100, 0)
	silent := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	silent.beginMedia(startedAt)
	frame := make([]byte, cloudPCMFrameBytes)
	for index := 0; index < 50; index++ {
		silent.observeDownlink(frame, startedAt.Add(time.Duration(index)*20*time.Millisecond), 2)
	}
	if got := silent.evaluate(startedAt.Add(time.Second)); got != cloudMediaHealthy {
		t.Fatalf("有效静音决策=%q，期望 %q", got, cloudMediaHealthy)
	}

	uplink := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	uplink.beginMedia(startedAt)
	nonSilent := make([]byte, cloudPCMFrameBytes)
	nonSilent[0], nonSilent[1] = 0x60, 0x09
	uplink.observeDownlink(nonSilent, startedAt.Add(6*time.Second), 1)
	if got := uplink.evaluate(startedAt.Add(6100 * time.Millisecond)); got != cloudMediaRebuildUplinkStalled {
		t.Fatalf("上行卡死决策=%q，期望 %q", got, cloudMediaRebuildUplinkStalled)
	}
}

func TestECMWatchdogFieldsCarryCurrentCallIdentity(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-ecm", CallUUID: "49f5fa4d-b8e4-4997-bb0b-dca076997344", Generation: 7,
	}
	fields := ecmWatchdogFields(
		ecmLinkMissing, "ecm-missing", "netdev removed",
		"qcom_ecm", "ecm0", "diag,ecm,ffs", &descriptor,
	)
	for key, want := range map[string]string{
		"driver": "qcom_ecm", "interface": "ecm0", "usb_functions": "diag,ecm,ffs",
		"call_id": "call-ecm", "call_uuid": "49f5fa4d-b8e4-4997-bb0b-dca076997344",
		"generation": "7", "state": "missing",
	} {
		if got := fields[key]; got != want {
			t.Fatalf("字段 %s=%q，期望 %q", key, got, want)
		}
	}
}

func TestCloudMediaTransportFallsBackUnlessRequestedProtocolIsSupported(t *testing.T) {
	if got := resolveCloudMediaTransport("webrtc", []string{"legacy_pcm"}, false); got != "legacy_pcm" {
		t.Fatalf("Agent 不支持 WebRTC 时传输=%q，期望 legacy_pcm", got)
	}
	if got := resolveCloudMediaTransport("webrtc", []string{"legacy_pcm", "webrtc"}, false); got != "webrtc" {
		t.Fatalf("双方支持 WebRTC 时传输=%q，期望 webrtc", got)
	}
	if got := resolveCloudMediaTransport("webrtc", []string{"legacy_pcm", "webrtc"}, true); got != "legacy_pcm" {
		t.Fatalf("强制回退时传输=%q，期望 legacy_pcm", got)
	}
}
