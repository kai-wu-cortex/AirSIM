package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPushHTTPClientToleratesSlowCellularTLS(t *testing.T) {
	client := newPushHTTPClient()
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("推送客户端 Transport 类型=%T", client.Transport)
	}
	if client.Timeout < 25*time.Second || transport.TLSHandshakeTimeout < 15*time.Second {
		t.Fatalf(
			"蜂窝 HTTPS 超时过短: client=%s tls=%s",
			client.Timeout, transport.TLSHandshakeTimeout,
		)
	}
}

func TestPushDNSFallbackPrefersReliableIPv4Resolvers(t *testing.T) {
	if len(pushDNSServers) < 2 || pushDNSServers[0] != "1.1.1.1:53" || pushDNSServers[1] != "8.8.8.8:53" {
		t.Fatalf("公网 DNS 顺序不可靠: %#v", pushDNSServers)
	}
	addresses := pushIPv4Addresses([]net.IPAddr{
		{IP: net.ParseIP("2606:4700:3037::6815:1e0")},
		{IP: net.ParseIP("104.21.1.224")},
	})
	if len(addresses) != 1 || addresses[0].String() != "104.21.1.224" {
		t.Fatalf("公网推送必须过滤不可达 IPv6: %#v", addresses)
	}
}

func testPushRegistration(relayURL string) pushRegistration {
	return pushRegistration{
		DeviceID: "iphone-air", DeviceSecret: strings.Repeat("s", 32),
		VoIPToken: strings.Repeat("a", 64), AlertToken: strings.Repeat("b", 64),
		WatchVoIPToken: strings.Repeat("c", 64),
		WatchBundleID:  "com.example.airsim.watchkitapp",
		BundleID:       "com.example.airsim", Environment: "sandbox", RelayURL: relayURL,
	}
}

func TestValidatePushRegistrationRequiresHTTPSRelay(t *testing.T) {
	registration := testPushRegistration("http://push.example.com")
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("公网推送中继使用明文 HTTP 时应被拒绝")
	}
	registration.RelayURL = "https://push.example.com"
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("合法推送注册被拒绝: %v", err)
	}
}

func TestPushRegistrationAcceptsEitherTokenButNotNeither(t *testing.T) {
	registration := testPushRegistration("https://push.example.com")
	registration.AlertToken = ""
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("仅 VoIP token 应可注册: %v", err)
	}
	registration.VoIPToken = ""
	registration.AlertToken = strings.Repeat("b", 64)
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("仅 alert token 应可注册: %v", err)
	}
	registration.AlertToken = ""
	registration.WatchVoIPToken = ""
	registration.WatchBundleID = ""
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("没有任何 APNs token 的注册应被拒绝")
	}
}

func TestPushRegistrationPersistsWithoutLeakingTokensOrSecretInStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	manager := newPushManager(path)
	registration := testPushRegistration("https://push.example.com")
	if err := manager.store(registration); err != nil {
		t.Fatal(err)
	}

	status := newPushManager(path).status()
	if !status.Configured || !status.CallPushReady || !status.MessagePushReady {
		t.Fatalf("持久化后状态不匹配: %#v", status)
	}
	encoded, _ := json.Marshal(status)
	for _, secret := range []string{registration.DeviceSecret, registration.VoIPToken, registration.AlertToken} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("状态接口泄漏了推送凭据: %s", encoded)
		}
	}
}

func TestPushManagerRestoresLastGoodRegistrationWhenPrimaryIsTruncated(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	manager := newPushManager(path)
	if err := manager.store(testPushRegistration("https://push.example.com")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	restored := newPushManager(path).status()
	if !restored.Configured || !restored.CallPushReady || !restored.MessagePushReady {
		t.Fatalf("主配置被截断后没有恢复最近有效注册: %#v", restored)
	}
	if restored.LastError != "" {
		t.Fatalf("成功恢复后不应继续显示配置错误: %q", restored.LastError)
	}
}

func TestWritePushConfigDataSyncFailurePreservesPublishedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	if err := os.WriteFile(path, []byte(`{"device_id":"old"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	wantError := errors.New("data sync failed")
	err := writePushConfigAtomicallyWithDurability(
		path,
		[]byte(`{"device_id":"new"}`),
		func(string) error { return wantError },
		func(string) error { return nil },
	)
	if !errors.Is(err, wantError) {
		t.Fatalf("数据尚未稳定落盘时必须阻止发布: %v", err)
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(data) != `{"device_id":"old"}` {
		t.Fatalf("同步失败却覆盖了已发布配置: %s", data)
	}
	if _, statErr := os.Stat(path + ".tmp"); !os.IsNotExist(statErr) {
		t.Fatalf("同步失败后临时文件没有清理: %v", statErr)
	}
}

func TestWritePushConfigDirectorySyncFailureIsReported(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	wantError := errors.New("directory sync failed")
	err := writePushConfigAtomicallyWithDurability(
		path,
		[]byte(`{"device_id":"new"}`),
		func(string) error { return nil },
		func(string) error { return wantError },
	)
	if !errors.Is(err, wantError) {
		t.Fatalf("目录项未确认稳定落盘时不得报告成功: %v", err)
	}
}

func TestIncomingCallRelayUsesStableUUIDAndDeduplicates(t *testing.T) {
	type payload struct {
		CallID     string `json:"call_id"`
		CallUUID   string `json:"call_uuid"`
		CallSecret string `json:"call_secret"`
	}
	var received []payload
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call" {
			t.Fatalf("请求路径=%q", request.URL.Path)
		}
		var value payload
		if err := json.NewDecoder(request.Body).Decode(&value); err != nil {
			t.Fatal(err)
		}
		received = append(received, value)
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	call := callRecord{ID: "call-9", Direction: "incoming", State: "incoming", Number: "10086"}
	if sent, err := manager.sendIncoming(call, time.Now()); err != nil || !sent {
		t.Fatalf("首次来电没有发送: sent=%v err=%v", sent, err)
	}
	if sent, err := manager.sendIncoming(call, time.Now()); err != nil || sent {
		t.Fatalf("重复来电不应再次发送: sent=%v err=%v", sent, err)
	}
	if len(received) != 1 || received[0].CallID != call.ID || received[0].CallUUID == "" ||
		len(received[0].CallSecret) < 24 {
		t.Fatalf("中继载荷错误: %#v", received)
	}
}

func TestPushRegistrationValidatesWatchVoIPIdentity(t *testing.T) {
	registration := testPushRegistration("https://push.example.com")
	registration.WatchBundleID = "com.attacker.watch"
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("Watch VoIP token 不得绑定到其他 App ID")
	}
	registration.WatchBundleID = ""
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("存在 Watch token 时必须提供 Watch bundle id")
	}
}

func TestCloudMediaURLRequiresTLSAndCarriesAgentRole(t *testing.T) {
	got, err := cloudMediaURL(
		"https://push.airsim.example", "D9B59660-05BB-4EA8-9AEB-4505B35C93F9",
		"call-secret-0123456789abcdef",
	)
	if err != nil {
		t.Fatal(err)
	}
	want := "wss://push.airsim.example/v1/calls/d9b59660-05bb-4ea8-9aeb-4505b35c93f9/connect?role=agent&token=call-secret-0123456789abcdef"
	if got != want {
		t.Fatalf("媒体地址=%q，期望 %q", got, want)
	}
	if _, err := cloudMediaURL("http://push.example.com", "call", "secret"); err == nil {
		t.Fatal("明文 Relay 不得生成媒体地址")
	}
}

func TestDecodeCloudCallActionAllowsOnlyBoundCall(t *testing.T) {
	for _, action := range []string{"answer", "reject", "end"} {
		value, err := decodeCloudCallAction([]byte(`{"action":"`+action+`","call_id":"call-9","owner":"iphone"}`), "call-9")
		if err != nil || value.Action != action || value.Owner != "iphone" {
			t.Fatalf("action=%s value=%#v err=%v", action, value, err)
		}
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"answer","call_id":"call-9","owner":"attacker"}`), "call-9"); err == nil {
		t.Fatal("公网控制不得伪造未知媒体所有者")
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"answer","call_id":"old"}`), "call-9"); err == nil {
		t.Fatal("旧通话控制不应被执行")
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"dial","call_id":"call-9"}`), "call-9"); err == nil {
		t.Fatal("公网媒体控制不得执行任意动作")
	}
}

func TestDecodeCloudCallActionCarriesStableTraceIdentity(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", Generation: 7,
	}
	value, err := decodeCloudCallActionForDescriptor([]byte(`{
		"action":"end","call_id":"call-9",
		"call_uuid":"d9b59660-05bb-4ea8-9aeb-4505b35c93f9","generation":7,
		"command_id":"9f9dc60b-3a36-4a0a-b87a-63a3ffb27145","trace_id":"9f9dc60b","owner":"iphone"
	}`), descriptor)
	if err != nil {
		t.Fatal(err)
	}
	fields := cloudCallTraceFields(descriptor, value)
	if fields["call_uuid"] != descriptor.CallUUID || fields["generation"] != "7" ||
		fields["command_id"] != value.CommandID || fields["trace_id"] != "9f9dc60b" {
		t.Fatalf("链路字段未完整保留: %#v", fields)
	}
	if _, err := decodeCloudCallActionForDescriptor(
		[]byte(`{"action":"end","call_id":"call-9","generation":6,"owner":"iphone"}`),
		descriptor,
	); err == nil {
		t.Fatal("旧 generation 的控制命令必须被拒绝")
	}
}

func TestCloudCommandURLKeepsPersistentSecretOutOfURL(t *testing.T) {
	registration := testPushRegistration("https://push.airsim.example")
	endpoint, err := cloudCommandURL(registration)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(endpoint, "/v1/devices/") || strings.Contains(endpoint, registration.DeviceSecret) {
		t.Fatalf("公网命令地址泄露设备密钥或路径错误: %q", endpoint)
	}
}

func TestExpiredCloudCommandIsRejectedAndDeduplicatedBeforeAT(t *testing.T) {
	agent := &agent{cloudCommandResults: make(map[string]cloudCommandResult)}
	command := cloudDeviceCommand{
		CommandID: "2d33c399-1030-4e9a-90ea-bb429e16ac5a",
		Type:      "dial", Number: "10086",
		ExpiresAt: time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano),
	}
	first := agent.executeCloudCommand(command)
	second := agent.executeCloudCommand(command)
	if first.Status != "failed" || first.Error != "云端命令已过期" ||
		second.Status != first.Status || second.Error != first.Error {
		t.Fatalf("过期命令结果不稳定: first=%#v second=%#v", first, second)
	}
}

func TestCloudPCMFramerPreservesTCPBoundaries(t *testing.T) {
	framer := cloudPCMFramer{}
	first := framer.append(make([]byte, 321))
	if len(first) != 1 || len(first[0]) != cloudPCMFrameBytes {
		t.Fatalf("首批帧=%d 长度=%v", len(first), frameLengths(first))
	}
	second := framer.append(make([]byte, 319))
	if len(second) != 1 || len(second[0]) != cloudPCMFrameBytes {
		t.Fatalf("跨 TCP read 的余数必须组成完整帧，帧=%d 长度=%v", len(second), frameLengths(second))
	}
	if framer.buffered() != 0 {
		t.Fatalf("完整两帧后不应剩余字节，实际=%d", framer.buffered())
	}
}

func TestCloudPCMReadTimeoutTriggersVoiceRouteRecovery(t *testing.T) {
	if !shouldRecoverCloudPCM(&net.OpError{Op: "read", Err: timeoutError{}}, 0) {
		t.Fatal("PCM 连接已建立但持续没有下行字节时必须重启语音桥")
	}
	if shouldRecoverCloudPCM(io.EOF, 12_800) {
		t.Fatal("已经传输过下行的普通 EOF 应交给连接重试，不应立即重置媒体路由")
	}
}

type timeoutError struct{}

func (timeoutError) Error() string   { return "timeout" }
func (timeoutError) Timeout() bool   { return true }
func (timeoutError) Temporary() bool { return true }

func frameLengths(frames [][]byte) []int {
	result := make([]int, len(frames))
	for index, frame := range frames {
		result[index] = len(frame)
	}
	return result
}

func TestCallOwnershipPreservesAuthenticatedIPhoneOwner(t *testing.T) {
	var received callOwnerPushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call-owner" {
			t.Fatalf("请求路径=%q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendCallOwner("call-9", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", "iphone", "active"); err != nil {
		t.Fatal(err)
	}
	if received.Owner != "iphone" || received.Phase != "active" || received.DeviceSecret == "" {
		t.Fatalf("所有权载荷错误: %#v", received)
	}
}

func TestPushManagerSendsActivityStateWithOriginalCallUUID(t *testing.T) {
	var received callStatePushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call-state" {
			t.Fatalf("path=%s", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	manager.config = testPushRegistration(server.URL)
	manager.lastCallID = "call-live"
	manager.lastUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9"

	manager.lastGeneration = 7
	if err := manager.sendCallState("call-live", "ringing"); err != nil {
		t.Fatal(err)
	}
	if received.CallUUID != manager.lastUUID || received.Phase != "ringing" ||
		received.Generation != 7 || received.Source != "agent" || received.Timestamp == "" {
		t.Fatalf("通话状态事件错误: %#v", received)
	}
}

func TestIncomingSMSUsesAlertEndpointAndDeduplicates(t *testing.T) {
	var received []incomingSMSPushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/sms" {
			t.Fatalf("请求路径=%q", request.URL.Path)
		}
		var value incomingSMSPushEvent
		if err := json.NewDecoder(request.Body).Decode(&value); err != nil {
			t.Fatal(err)
		}
		received = append(received, value)
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	message := smsMessage{
		Sender: "10010", Content: "余额提醒", Timestamp: time.Now(), DeliveryID: "SM-7-test",
	}
	if sent, err := manager.sendSMS(message); err != nil || !sent {
		t.Fatalf("首次短信没有发送: sent=%v err=%v", sent, err)
	}
	if sent, err := manager.sendSMS(message); err != nil || sent {
		t.Fatalf("重复短信不应再次发送: sent=%v err=%v", sent, err)
	}
	if len(received) != 1 || received[0].DeliveryID != message.DeliveryID || received[0].Content != message.Content {
		t.Fatalf("短信中继载荷错误: %#v", received)
	}
}

func TestAgentHeartbeatReportsCellularStateWithoutSecrets(t *testing.T) {
	var received agentHeartbeatEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/heartbeat" {
			t.Fatalf("请求路径=%q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendHeartbeat(agentHeartbeatSnapshot{
		ATOK: true, CellularState: "searching", CellularRegistration: "搜索中",
		CellularRecovery: "正在自动选网", ECMCarrier: "1", SignalDBM: intPointer(-91),
	}); err != nil {
		t.Fatal(err)
	}
	if received.Event != "agent_heartbeat" || received.CellularState != "searching" ||
		received.DeviceSecret == "" || received.SignalDBM == nil || *received.SignalDBM != -91 {
		t.Fatalf("心跳载荷错误: %#v", received)
	}
}

func TestPushManagerCloudModeDisablesPublicEvents(t *testing.T) {
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests++
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.setCloudEnabled(false); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendHeartbeat(agentHeartbeatSnapshot{ATOK: true, CellularState: "registered"}); err != nil {
		t.Fatal(err)
	}
	if sent, err := manager.sendSMS(smsMessage{
		Sender: "10010", Content: "余额提醒", Timestamp: time.Now(), DeliveryID: "disabled-sms",
	}); err != nil || sent {
		t.Fatalf("云端模式关闭后不应发送短信中继: sent=%v err=%v", sent, err)
	}
	if requests != 0 {
		t.Fatalf("云端模式关闭后仍产生 %d 个公网请求", requests)
	}
	if manager.status().CloudEnabled {
		t.Fatal("状态仍报告云端模式开启")
	}
}

func intPointer(value int) *int { return &value }

func TestNonRingingCallsNeverProduceVoIPPush(t *testing.T) {
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	for _, call := range []callRecord{
		{ID: "out", Direction: "outgoing", State: "incoming"},
		{ID: "active", Direction: "incoming", State: "active"},
	} {
		if sent, err := manager.sendIncoming(call, time.Now()); err != nil || sent {
			t.Fatalf("非振铃呼入不应发送 VoIP Push: call=%#v sent=%v err=%v", call, sent, err)
		}
	}
}
