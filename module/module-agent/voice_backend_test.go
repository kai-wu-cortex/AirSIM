package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"testing"
	"time"
)

func TestVoiceBackendDefaultsToSamsungAndRequiresPrivateEndpoint(t *testing.T) {
	_, err := loadVoiceBackend(func(string) string { return "" })
	if err == nil {
		t.Fatal("未设置三星 PCM 私网端点时必须拒绝启动")
	}
	config, err := loadVoiceBackend(func(key string) string {
		if key == "DJONEHUB_SAMSUNG_PCM_ADDRESS" { return "192.168.240.1:7580" }
		return ""
	})
	if err != nil {
		t.Fatalf("默认语音后端失败: %v", err)
	}
	if config.kind != voiceBackendSamsungAndroid {
		t.Fatalf("默认后端=%q，期望 %q", config.kind, voiceBackendSamsungAndroid)
	}
	if config.endpoint != "192.168.240.1:7580" {
		t.Fatalf("默认端点=%q", config.endpoint)
	}
	if config.requiresLocalRuntime() {
		t.Fatal("AirSIM 不得准备 QDC507 本机语音运行时")
	}
}

func TestSamsungVoiceBackendRequiresExplicitPrivateEndpoint(t *testing.T) {
	lookup := func(key string) string {
		values := map[string]string{
			"DJONEHUB_VOICE_BACKEND":       "samsung_android",
			"DJONEHUB_SAMSUNG_PCM_ADDRESS": "192.168.240.1:7580",
		}
		return values[key]
	}
	config, err := loadVoiceBackend(lookup)
	if err != nil {
		t.Fatalf("三星语音后端失败: %v", err)
	}
	if config.kind != voiceBackendSamsungAndroid {
		t.Fatalf("三星后端=%q", config.kind)
	}
	if config.endpoint != "192.168.240.1:7580" {
		t.Fatalf("三星端点=%q", config.endpoint)
	}
	if config.requiresLocalRuntime() {
		t.Fatal("三星后端不得启动 QDC507 内核或混音器运行时")
	}
}

func TestSamsungVoiceBackendRejectsUnsafeEndpoints(t *testing.T) {
	for _, endpoint := range []string{
		"", "0.0.0.0:7580", "127.0.0.1:7580", "8.8.8.8:7580",
		"bridge.example.com:7580", "192.168.240.1:80", "192.168.240.1:70000",
	} {
		t.Run(endpoint, func(t *testing.T) {
			_, err := loadVoiceBackend(func(key string) string {
				if key == "DJONEHUB_VOICE_BACKEND" {
					return "samsung_android"
				}
				return endpoint
			})
			if err == nil {
				t.Fatalf("不安全端点 %q 应被拒绝", endpoint)
			}
		})
	}
}

func TestVoiceBackendRejectsUnknownKind(t *testing.T) {
	_, err := loadVoiceBackend(func(key string) string {
		if key == "DJONEHUB_VOICE_BACKEND" {
			return "other"
		}
		return ""
	})
	if err == nil {
		t.Fatal("未知语音后端应被拒绝")
	}
}

func TestHealthReportsVoiceBackendWithoutEndpoint(t *testing.T) {
	service := &agent{
		at: newATPort("unused"), started: time.Now(),
		voiceBackend: voiceBackendConfig{
			kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
		},
	}
	request := httptest.NewRequest("GET", "/api/health", nil)
	recorder := httptest.NewRecorder()
	service.health(recorder, request)
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["voice_backend"] != "samsung_android" {
		t.Fatalf("健康接口语音后端=%v", payload["voice_backend"])
	}
	if payload["ok"] != true {
		t.Fatalf("三星外部后端配置有效时 Agent 应在线: ok=%v", payload["ok"])
	}
	if _, exposed := payload["voice_pcm_endpoint"]; exposed {
		t.Fatal("健康接口不得暴露三星 PCM 私有端点")
	}

	platformRequest := httptest.NewRequest("GET", "/api/platform", nil)
	platformRecorder := httptest.NewRecorder()
	service.platform(platformRecorder, platformRequest)
	var platform map[string]any
	if err := json.Unmarshal(platformRecorder.Body.Bytes(), &platform); err != nil {
		t.Fatal(err)
	}
	if platform["call_audio"] != true {
		t.Fatalf("三星外部后端应报告通话音频能力: %v", platform["call_audio"])
	}
}

func TestAgentExposesConfiguredPCMEndpointAndRuntimeBoundary(t *testing.T) {
	service := &agent{voiceBackend: voiceBackendConfig{
		kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
	}}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatalf("读取 PCM 端点失败: %v", err)
	}
	if endpoint != "192.168.240.1:7580" {
		t.Fatalf("PCM 端点=%q", endpoint)
	}
	if service.usesLocalVoiceRuntime() {
		t.Fatal("三星 Agent 不得准备 QDC507 本机运行时")
	}

	invalid := &agent{voiceBackendErr: errTestVoiceBackend}
	if _, err := invalid.voicePCMEndpoint(); err == nil {
		t.Fatal("无效后端配置不得返回 PCM 端点")
	}
}

func TestSamsungVoiceBackendFollowsCurrentAVFDefaultGateway(t *testing.T) {
	service := &agent{
		profile: runtimeProfileFrom("android-avf"),
		voiceBackend: voiceBackendConfig{
			kind: voiceBackendSamsungAndroid, endpoint: "10.185.5.63:7580",
		},
		defaultRoute: func() map[string]string {
			return map[string]string{"interface": "enp0s7", "gateway": "172.29.240.24"}
		},
	}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatalf("读取动态 PCM 端点失败: %v", err)
	}
	if endpoint != "172.29.240.24:7580" {
		t.Fatalf("PCM 端点=%q，期望当前 AVF 网关 172.29.240.24:7580", endpoint)
	}
}

func TestQDC507VoiceBackendKeepsFixedEndpoint(t *testing.T) {
	service := &agent{
		profile:      runtimeProfileFrom("qdc507"),
		voiceBackend: voiceBackendConfig{kind: voiceBackendQDC507, endpoint: qdc507PCMEndpoint},
		defaultRoute: func() map[string]string {
			return map[string]string{"interface": "ecm0", "gateway": "172.29.240.24"}
		},
	}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != qdc507PCMEndpoint {
		t.Fatalf("QDC507 PCM 端点被错误改写为 %q", endpoint)
	}
}

func TestSamsungVoiceRouteDoesNotStartQDC507Processes(t *testing.T) {
	service := &agent{voiceBackend: voiceBackendConfig{
		kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
	}}
	service.ensureVoiceRoute()
	snapshot := service.voice.snapshot()
	if !snapshot.Listening || snapshot.Ready {
		t.Fatalf("握手前应仅标记监听可用: listening=%v ready=%v error=%q",
			snapshot.Listening, snapshot.Ready, snapshot.LastError)
	}
	if snapshot.Command != nil || snapshot.RouteCommand != nil || snapshot.MediaRouteStarted {
		t.Fatal("三星后端不得启动 QDC507 helper、路由进程或基带媒体路由")
	}
	service.markVoiceBackendHandshakeReady()
	if !service.voice.snapshot().Ready {
		t.Fatal("DJ1READY 握手后应标记三星 PCM 后端就绪")
	}
	service.stopVoiceRoute()
	stopped := service.voice.snapshot()
	if stopped.Ready || stopped.Listening {
		t.Fatal("停止三星语音路由后应清除监听和就绪状态")
	}
}

func TestProbeVoicePCMBackendPerformsLegacyHandshake(t *testing.T) {
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		hello := make([]byte, len("DJ1PCM1\n"))
		if _, err := io.ReadFull(server, hello); err != nil {
			done <- err
			return
		}
		if string(hello) != "DJ1PCM1\n" {
			done <- &voiceBackendTestError{}
			return
		}
		if _, err := server.Write([]byte("DJ1READY")); err != nil {
			done <- err
			return
		}
		one := make([]byte, 1)
		_, err := server.Read(one)
		if err == io.EOF {
			err = nil
		}
		done <- err
	}()

	err := probeVoicePCMBackend("192.168.240.1:7580", func(_, _ string) (net.Conn, error) {
		return client, nil
	})
	if err != nil {
		t.Fatalf("PCM 后端握手失败: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("模拟桥失败: %v", err)
	}
}

var errTestVoiceBackend = &voiceBackendTestError{}

type voiceBackendTestError struct{}

func (*voiceBackendTestError) Error() string { return "voice backend invalid" }
