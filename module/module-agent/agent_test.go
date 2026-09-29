package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	sgp22 "github.com/damonto/euicc-go/v2"
)

func TestRequestAdmissionReservesCallControlCapacity(t *testing.T) {
	admission := newRequestAdmission(1, 1, 1)
	release, ok := admission.acquire(context.Background(), "/api/status")
	if !ok {
		t.Fatal("第一个普通状态请求应获准")
	}
	defer release()
	if _, ok := admission.acquire(context.Background(), "/api/router/status"); ok {
		t.Fatal("普通请求通道饱和时应快速拒绝")
	}
	criticalRelease, ok := admission.acquire(context.Background(), "/api/calls/hangup")
	if !ok {
		t.Fatal("普通请求饱和不应阻塞挂断控制")
	}
	criticalRelease()
}

func TestAudioHostConfigExposesListenerReadinessBeforeHandshake(t *testing.T) {
	service := &agent{}
	service.voice.mu.Lock()
	service.voice.listening = true
	service.voice.ready = false
	service.voice.mu.Unlock()

	request := httptest.NewRequest(http.MethodGet, "/api/calls/audio/host/config", nil)
	response := httptest.NewRecorder()
	service.audioHostConfig(response, request)

	var payload map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["route_listening"] != true {
		t.Fatalf("route_listening=%v, want true", payload["route_listening"])
	}
	if payload["route_ready"] != false {
		t.Fatalf("route_ready=%v, want false before DJ1READY", payload["route_ready"])
	}
}

func TestRequestAdmissionSeparatesLongPolls(t *testing.T) {
	admission := newRequestAdmission(1, 1, 1)
	release, ok := admission.acquire(context.Background(), "/api/events")
	if !ok {
		t.Fatal("首个长轮询应获准")
	}
	defer release()
	normalRelease, ok := admission.acquire(context.Background(), "/api/status")
	if !ok {
		t.Fatal("长轮询不应占用普通状态请求通道")
	}
	normalRelease()
}

func TestAndroidCommandPollHasReservedAdmission(t *testing.T) {
	admission := newRequestAdmission(1, 1, 2)
	firstRelease, ok := admission.acquire(context.Background(), "/api/events")
	if !ok {
		t.Fatal("首个 iPhone 事件长轮询应获准")
	}
	defer firstRelease()
	secondRelease, ok := admission.acquire(context.Background(), "/api/calls/events")
	if !ok {
		t.Fatal("第二个 iPhone 事件长轮询应获准")
	}
	defer secondRelease()

	androidRelease, ok := admission.acquire(context.Background(), "/api/android/commands/next")
	if !ok {
		t.Fatal("iPhone 长轮询饱和时必须为 Android 命令轮询保留容量")
	}
	androidRelease()

	if got := classifyRequest("/api/android/commands/result"); got != requestClassControl {
		t.Fatalf("Android command result class=%v, want control", got)
	}
}

func TestOperationFlightCoalescesConcurrentHangups(t *testing.T) {
	var flight operationFlight
	started := make(chan struct{})
	finish := make(chan struct{})
	var mu sync.Mutex
	runs := 0
	operation := func() error {
		mu.Lock()
		runs++
		mu.Unlock()
		close(started)
		<-finish
		return nil
	}
	results := make(chan error, 2)
	go func() { results <- flight.Do(operation) }()
	<-started
	go func() { results <- flight.Do(operation) }()
	// 给第二个请求进入已存在 flight 的机会；首个操作仍被 finish 门锁住。
	time.Sleep(10 * time.Millisecond)
	close(finish)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatalf("合并挂断返回错误: %v", err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if runs != 1 {
		t.Fatalf("并发挂断实际执行 %d 次，期望 1 次", runs)
	}
}

func TestVoiceRuntimeValidatorCachesStreamingValidation(t *testing.T) {
	directory := t.TempDir()
	payload := strings.Repeat("voice-runtime", 100_000)
	path := filepath.Join(directory, "runtime.bin")
	if err := os.WriteFile(path, []byte(payload), 0o644); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256([]byte(payload))
	files := map[string]string{"runtime.bin": hex.EncodeToString(digest[:])}
	var validator voiceRuntimeValidator
	installed, err := validator.validate(directory, files)
	if err != nil || !installed {
		t.Fatalf("初次流式校验失败: installed=%v err=%v", installed, err)
	}
	if err := os.WriteFile(path, []byte("changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	installed, err = validator.validate(directory, files)
	if err != nil || !installed {
		t.Fatalf("同一进程内应复用已通过的校验结果: installed=%v err=%v", installed, err)
	}
}

func TestAllowedRemote(t *testing.T) {
	tests := []struct {
		remote string
		want   bool
	}{
		{"192.168.225.2:54321", true},
		{"192.168.225.254:1", true},
		{"127.0.0.1:7575", true},
		{"[::1]:7575", true},
		{"10.185.5.63:41000", true},
		{"192.168.224.2:7575", false},
		{"10.185.6.63:41000", false},
		{"8.8.8.8:53", false},
		{"invalid", false},
	}
	for _, test := range tests {
		if got := allowedRemote(test.remote); got != test.want {
			t.Errorf("allowedRemote(%q)=%v，期望 %v", test.remote, got, test.want)
		}
	}
}

func TestAndroidAVFAllowsPrivatePeerOnDirectlyConnectedSubnet(t *testing.T) {
	networks := []*net.IPNet{
		{IP: net.ParseIP("172.29.240.25").To4(), Mask: net.CIDRMask(24, 32)},
	}
	if !allowedRemoteWithNetworks("172.29.240.24:41000", runtimeProfileFrom("android-avf"), networks) {
		t.Fatal("current AVF host peer should be accepted")
	}
	if allowedRemoteWithNetworks("172.29.241.24:41000", runtimeProfileFrom("android-avf"), networks) {
		t.Fatal("unrelated private subnet must remain rejected")
	}
}

func TestCompareModuleVersions(t *testing.T) {
	tests := []struct {
		left, right string
		want        int
	}{
		{"0.3.0", "0.2.8", 1},
		{"0.3.0", "0.3.0", 0},
		{"0.2.9", "0.3.0", -1},
		{"1.0", "1.0.0", 0},
	}
	for _, test := range tests {
		if got := compareModuleVersions(test.left, test.right); got != test.want {
			t.Errorf("compareModuleVersions(%q,%q)=%d，期望 %d", test.left, test.right, got, test.want)
		}
	}
}

func TestValidateModuleUpdateManifestRejectsIncompleteOrWrongTarget(t *testing.T) {
	validFiles := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		validFiles = append(validFiles, moduleUpdateFile{
			Name: name, Target: target.target, SHA256: strings.Repeat("a", 64), Size: 1, Mode: target.mode,
		})
	}
	manifest := moduleUpdateManifest{
		FormatVersion: moduleUpdateFormat,
		Version:       "0.3.7",
		Platform:      moduleUpdatePlatform,
		Files:         validFiles,
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		t.Fatalf("合法更新清单被拒绝: %v", err)
	}
	manifest.Files[0].Target = "bin/unsafe"
	if err := validateModuleUpdateManifest(manifest); err == nil {
		t.Fatal("更新清单中的越界目标未被拒绝")
	}
}

func TestWriteVoiceMediaRoutePreservesCommands(t *testing.T) {
	path := t.TempDir() + "/voc_svr"
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := writeVoiceMediaRoute(path, "S\n"); err != nil {
		t.Fatalf("写入语音启动命令失败: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "S\n" {
		t.Fatalf("语音启动命令=%q，期望 %q", data, "S\\n")
	}
}

func TestVoiceHelperChecksumMatchesBuiltArtifact(t *testing.T) {
	path := filepath.Join("pcm-bridge", voiceHelperName)
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		t.Skip("尚未构建 PCM helper")
	}
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(data)
	if actual := hex.EncodeToString(digest[:]); actual != voiceHelperSHA256 {
		t.Fatalf("PCM helper SHA-256=%s，Agent 白名单=%s", actual, voiceHelperSHA256)
	}
}

func TestParseCLCC(t *testing.T) {
	response := "+CLCC: 1,1,4,0,0,\"+8613800138000\",145\r\n" +
		"+CLCC: 2,0,0,1,0,\"data\",129\r\nOK\r\n"
	calls := parseCLCC(response)
	if len(calls) != 1 {
		t.Fatalf("语音通话数量=%d，期望 1", len(calls))
	}
	if calls[0].Direction != "incoming" || calls[0].State != "incoming" || calls[0].Number != "+8613800138000" {
		t.Fatalf("通话解析错误: %#v", calls[0])
	}
}

func TestParseDSCIIncomingAndEnd(t *testing.T) {
	call, ended, ok := parseDSCI(`^DSCI: 1,1,4,0,13022100000,129,0`)
	if !ok || ended || call.Index != 1 || call.Direction != "incoming" ||
		call.State != "incoming" || call.Number != "13022100000" {
		t.Fatalf("来电 DSCI 解析错误: call=%#v ended=%v ok=%v", call, ended, ok)
	}
	_, ended, ok = parseDSCI(`^DSCI: 1,1,6,0,13022100000,129,0`)
	if !ok || !ended {
		t.Fatalf("结束 DSCI 解析错误: ended=%v ok=%v", ended, ok)
	}
	if _, _, ok := parseDSCI(`^DSCI: 1,1,4,1,data,129,0`); ok {
		t.Fatal("PS 会话不应被解析为语音通话")
	}
}

func TestATPortDispatchesChunkedURCWithoutTreatingResponsesAsEvents(t *testing.T) {
	port := newATPort("unused")
	var lines []string
	port.urcHandler = func(line string) { lines = append(lines, line) }
	pending := port.dispatchCompleteURCLines(nil, []byte("\r\n^DSCI: 1,1,"))
	pending = port.dispatchCompleteURCLines(pending, []byte("4,0,10086,129,0\r\n+CLCC: 1,1,4,0,0\r\n"))
	if len(pending) != 0 {
		t.Fatalf("URC 分块后仍有残留: %q", pending)
	}
	if len(lines) != 1 || lines[0] != "^DSCI: 1,1,4,0,10086,129,0" {
		t.Fatalf("URC 分发结果错误: %#v", lines)
	}
}

func TestParseSMSStorageURC(t *testing.T) {
	notice, ok := parseSMSStorageURC(`+CMTI: "SM",7`)
	if !ok || notice.Memory != "SM" || notice.Index != 7 {
		t.Fatalf("短信存储 URC 解析错误: notice=%#v ok=%v", notice, ok)
	}
}

func TestApplyCallPollRecordsMissedCall(t *testing.T) {
	a := &agent{}
	started := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	a.applyCallPoll([]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}, started)
	a.applyCallPoll(nil, started.Add(3*time.Second))
	if a.calls.Active != nil || len(a.calls.History) != 1 {
		t.Fatalf("通话结束状态错误: active=%#v history=%d", a.calls.Active, len(a.calls.History))
	}
	if !a.calls.History[0].Missed || a.calls.History[0].EndedAt == nil {
		t.Fatalf("未接来电记录错误: %#v", a.calls.History[0])
	}
}

func TestEndedDSCIRejectsStaleCLCCResurrection(t *testing.T) {
	a := &agent{}
	started := time.Now()
	incoming := parsedCall{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}
	a.applyCallPoll([]parsedCall{incoming}, started)
	if a.calls.Active == nil {
		t.Fatal("来电没有进入 active tracker")
	}
	originalID := a.calls.Active.ID

	// 基带先通过 URC 明确通知通话结束，但紧邻的一次 AT+CLCC 仍可能返回旧缓存。
	a.handleURC(`^DSCI: 1,1,6,0,10086,129,0`)
	a.applyCallPoll([]parsedCall{incoming}, started.Add(1500*time.Millisecond))

	if a.calls.Active != nil {
		t.Fatalf("陈旧 CLCC 重新创建了来电: %#v", a.calls.Active)
	}
	if len(a.calls.History) != 1 || a.calls.History[0].ID != originalID {
		t.Fatalf("结束记录被重复或替换: %#v", a.calls.History)
	}
}

func TestUSBSoftwareReconnectRequiresIdleECMOnlyProfile(t *testing.T) {
	if err := validateUSBSoftwareReconnect(false, false, "diag,ecm,ffs"); err != nil {
		t.Fatalf("空闲 ECM 组合应允许软件重连: %v", err)
	}
	for name, test := range map[string]struct {
		callActive  bool
		voiceActive bool
		functions   string
	}{
		"通话中":     {callActive: true, functions: "diag,ecm,ffs"},
		"媒体路由运行":  {voiceActive: true, functions: "diag,ecm,ffs"},
		"缺少ECM":   {functions: "diag,ffs"},
		"包含串口":    {functions: "diag,serial,ecm,ffs"},
		"包含USB音频": {functions: "diag,ecm,ffs,audio"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateUSBSoftwareReconnect(test.callActive, test.voiceActive, test.functions); err == nil {
				t.Fatal("危险状态不应允许 USB 软件重连")
			}
		})
	}
}

func TestCallHistoryAckRemovesOnlyConfirmedRecords(t *testing.T) {
	a := &agent{calls: callTracker{History: []callRecord{{ID: "keep"}, {ID: "remove"}}}}
	request := httptest.NewRequest("POST", "/api/calls/history/ack", strings.NewReader(`{"ids":["remove"]}`))
	response := httptest.NewRecorder()
	a.callHistoryAck(response, request)
	if response.Code != 200 {
		t.Fatalf("确认接口状态=%d，响应=%s", response.Code, response.Body.String())
	}
	if len(a.calls.History) != 1 || a.calls.History[0].ID != "keep" {
		t.Fatalf("确认后通话队列错误: %#v", a.calls.History)
	}
}

func TestUCS2RoundTripAndSplit(t *testing.T) {
	value := "验证码 123456，测试🙂"
	encoded := encodeUCS2(value)
	if decoded := decodeMaybeUCS2(encoded); decoded != value {
		t.Fatalf("UCS2 往返=%q，期望 %q", decoded, value)
	}
	segments := splitUCS2("A🙂B", 2)
	if len(segments) != 3 || segments[0] != "A" || segments[1] != "🙂" || segments[2] != "B" {
		t.Fatalf("代理对拆分错误: %#v", segments)
	}
}

func TestParseTextModeSMS(t *testing.T) {
	response := "+CMGL: 7,\"REC READ\",\"002B0038003600310033003800300030003100330038003000300030\",,\"26/08/15,12:34:56+32\"\r\n" +
		"9A8C8BC17801662F003100320033003400350036\r\nOK\r\n"
	items := parseTextModeSMS(response, "ME")
	if len(items) != 1 {
		t.Fatalf("短信数量=%d，期望 1", len(items))
	}
	message := items[0].Message
	if message.Sender != "+8613800138000" || message.Content != "验证码是123456" || message.Code != "123456" {
		t.Fatalf("短信解析错误: %#v", message)
	}
	_, offset := message.Timestamp.Zone()
	if offset != 8*60*60 {
		t.Fatalf("短信时区偏移=%d，期望 28800", offset)
	}
	if message.DeliveryID == "" || !containsStoredSMS(items, items[0]) {
		t.Fatalf("短信交付标识或去重状态错误: %#v", items[0])
	}
}

func TestParseModemFields(t *testing.T) {
	if got := parseSignalDBM("+CSQ: 29,99\r\nOK"); got == nil || *got != -55 {
		t.Fatalf("信号解析=%v，期望 -55", got)
	}
	mode, band := parseNetworkInfo(`+QNWINFO: "FDD LTE","46001","LTE BAND 3",1650`)
	if mode != "FDD LTE" || band != "BAND 3" {
		t.Fatalf("网络解析 mode=%q band=%q", mode, band)
	}
	if got := normalizeOperator("CHN-UNICOM"); got != "中国联通" {
		t.Fatalf("运营商规范化=%q", got)
	}
}

func TestGPSRefreshExecutesQGPSLOCWhenEnabled(t *testing.T) {
	var commands []string
	a := &agent{
		gps: gpsTracker{Enabled: true},
		gpsCommand: func(command string, timeout time.Duration) (string, error) {
			commands = append(commands, command)
			return "+QGPSLOC: 120000.0,22.7261,113.8420,0.8,42.1,1,0.0,0.0,0.0,18082026,12\r\nOK", nil
		},
	}
	request := httptest.NewRequest(http.MethodPost, "/api/gps/refresh", nil)
	response := httptest.NewRecorder()

	a.gpsRefresh(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("GPS 刷新状态=%d，响应=%s", response.Code, response.Body.String())
	}
	if len(commands) != 1 || commands[0] != "AT+QGPSLOC=2" {
		t.Fatalf("GPS 刷新 AT 指令=%#v，期望 [AT+QGPSLOC=2]", commands)
	}
	for _, expected := range []string{`"latitude":"22.7261"`, `"longitude":"113.8420"`, `"satellites":"12"`} {
		if !strings.Contains(response.Body.String(), expected) {
			t.Fatalf("GPS 刷新响应缺少 %s: %s", expected, response.Body.String())
		}
	}
}

func TestGPSRefreshPersistsNoFixError(t *testing.T) {
	a := &agent{
		gps: gpsTracker{Enabled: true},
		gpsCommand: func(command string, timeout time.Duration) (string, error) {
			return "OK", nil
		},
	}
	request := httptest.NewRequest(http.MethodPost, "/api/gps/refresh", nil)
	response := httptest.NewRecorder()

	a.gpsRefresh(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("GPS 无定位状态=%d，期望 %d", response.Code, http.StatusServiceUnavailable)
	}
	if a.gps.LastError != "暂未获得定位，请移至窗边或室外后重试" {
		t.Fatalf("GPS 无定位错误未写入状态: %q", a.gps.LastError)
	}
}

func TestParseUSBConfigurationRefusesMalformedInput(t *testing.T) {
	valid := `+QCFG: "usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` + "\r\nOK"
	configuration, err := parseUSBConfiguration(valid)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("合法 USBCFG 解析失败: config=%#v err=%v", configuration, err)
	}
	if _, err := parseUSBConfiguration(`+QCFG: "usbcfg",0x2C7C,0x0125,1`); err == nil {
		t.Fatal("畸形 USBCFG 未被拒绝")
	}
}

func TestInferQDC507USBConfigurationFromGadget(t *testing.T) {
	files := map[string]string{
		usbGadgetPath + "/idVendor":  "2c7c\n",
		usbGadgetPath + "/idProduct": "0125\n",
		usbGadgetPath + "/functions": "diag,ecm,ffs\n",
	}
	readFile := func(path string) ([]byte, error) {
		value, ok := files[path]
		if !ok {
			return nil, os.ErrNotExist
		}
		return []byte(value), nil
	}
	configuration, raw, err := inferQDC507USBConfiguration(readFile)
	if err != nil || configuration.uacEnabled() || raw != "gadget functions=diag,ecm,ffs" {
		t.Fatalf("移动模式推断错误: config=%#v raw=%q err=%v", configuration, raw, err)
	}
	if got := configuration.withUAC(true); got != `AT+QCFG="usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` {
		t.Fatalf("Mac 模式命令=%q", got)
	}
	files[usbGadgetPath+"/functions"] = "diag,serial,ecm,ffs,audio\n"
	configuration, _, err = inferQDC507USBConfiguration(readFile)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("Mac 模式推断错误: config=%#v err=%v", configuration, err)
	}
}

func TestInferQDC507USBConfigurationRejectsUnknownHardware(t *testing.T) {
	readFile := func(path string) ([]byte, error) {
		values := map[string]string{
			usbGadgetPath + "/idVendor":  "ffff",
			usbGadgetPath + "/idProduct": "0125",
			usbGadgetPath + "/functions": "diag,ecm,ffs",
		}
		return []byte(values[path]), nil
	}
	if _, _, err := inferQDC507USBConfiguration(readFile); err == nil {
		t.Fatal("未知硬件不应使用固定 USBCFG 回退")
	}
}

func TestPersistUSBModeMarkerTracksExplicitMacSelection(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "usb-mode-mac")
	if changed, err := persistUSBModeMarker(marker, "mac"); err != nil || !changed {
		t.Fatalf("写入 Mac 模式标记失败: %v", err)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "mac\n" {
		t.Fatalf("Mac 模式标记=%q err=%v", data, err)
	}
	if changed, err := persistUSBModeMarker(marker, "mobile"); err != nil || !changed {
		t.Fatalf("删除 Mac 模式标记失败: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("手机模式仍保留 Mac 标记: %v", err)
	}
}

func TestRoutesRejectPublicRemote(t *testing.T) {
	a := &agent{started: time.Now()}
	request := httptest.NewRequest("GET", "/api/health", nil)
	request.RemoteAddr = "203.0.113.9:54321"
	recorder := httptest.NewRecorder()
	a.routes(testLogger()).ServeHTTP(recorder, request)
	if recorder.Code != 403 {
		t.Fatalf("公网访问状态码=%d，期望 403", recorder.Code)
	}
}

func TestCoreCallAndSMSRoutesRemainAvailableForLegacyApps(t *testing.T) {
	a := newAgent("unused")
	handler := a.routes(testLogger())
	paths := []string{
		"/api/calls/status",
		"/api/calls/dial",
		"/api/calls/answer",
		"/api/calls/hangup",
		"/api/calls/audio/host/register",
		"/api/sms",
		"/api/sms/status",
		"/api/sms/send",
	}
	for _, path := range paths {
		// GET executes read-only routes and makes mutation routes return 405. Both
		// prove that the exact legacy path is registered without issuing an AT command.
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.RemoteAddr = "127.0.0.1:10001"
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code == http.StatusNotFound {
			t.Errorf("legacy core route unavailable: %s status=%d body=%s", path, response.Code, response.Body.String())
		}
	}
}

func TestDebugEndpointCapturesHTTPInputAndOutput(t *testing.T) {
	a := newAgent("unused")
	handler := a.routes(testLogger())

	platformRequest := httptest.NewRequest("GET", "/api/platform", nil)
	platformRequest.RemoteAddr = "127.0.0.1:10001"
	platformRequest.Header.Set("X-DJOneHub-Trace-ID", "trace-http-platform")
	platformResponse := httptest.NewRecorder()
	handler.ServeHTTP(platformResponse, platformRequest)
	if platformResponse.Code != http.StatusOK {
		t.Fatalf("平台接口状态=%d", platformResponse.Code)
	}

	debugRequest := httptest.NewRequest("GET", "/?limit=50", nil)
	debugRequest.RemoteAddr = "127.0.0.1:10002"
	debugResponse := httptest.NewRecorder()
	handler.ServeHTTP(debugResponse, debugRequest)
	if debugResponse.Code != http.StatusOK {
		t.Fatalf("Debug 接口状态=%d，响应=%s", debugResponse.Code, debugResponse.Body.String())
	}
	body := debugResponse.Body.String()
	for _, expected := range []string{`"events"`, `GET /api/platform`, `"category":"http"`, `"trace_id":"trace-http-platform"`, `"version":"` + agentVersion + `"`} {
		if !strings.Contains(body, expected) {
			t.Fatalf("Debug 响应缺少 %q: %s", expected, body)
		}
	}
}

func TestCallEventsWaitIsReleasedByMeaningfulCallChange(t *testing.T) {
	a := newAgent("unused")
	request := httptest.NewRequest(http.MethodGet, "/api/calls/events?after=0&timeout_ms=500", nil)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.callEvents(response, request)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("长轮询在通话状态变化前提前返回")
	case <-time.After(20 * time.Millisecond):
	}

	a.applyCallPoll([]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}, time.Now())
	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("通话状态变化没有唤醒长轮询")
	}

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Active   *callRecord `json:"active"`
		Revision uint64      `json:"revision"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Active == nil || payload.Active.Number != "10086" || payload.Revision == 0 {
		t.Fatalf("unexpected event payload: %+v", payload)
	}
}

func TestAgentEventsWaitIsReleasedByNewSMS(t *testing.T) {
	a := newAgent("unused")
	request := httptest.NewRequest(http.MethodGet, "/api/events?after=0&timeout_ms=500", nil)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.agentEvents(response, request)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("统一事件等待在新短信到达前提前返回")
	case <-time.After(20 * time.Millisecond):
	}

	message := storedSMS{
		Index:  7,
		Memory: "SM",
		Message: smsMessage{
			Sender: "+8610010", Content: "测试短信", Timestamp: time.Now(), DeliveryID: "SM-7-test",
		},
	}
	a.mergeSMS([]storedSMS{message})

	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("新短信没有唤醒统一事件等待")
	}

	if response.Code != http.StatusOK {
		t.Fatalf("统一事件状态=%d，响应=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Revision    uint64 `json:"revision"`
		SMSRevision uint64 `json:"sms_revision"`
		SMSPending  int    `json:"sms_pending"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Revision == 0 || payload.SMSRevision == 0 || payload.SMSPending != 1 {
		t.Fatalf("统一短信事件载荷错误: %+v", payload)
	}
}

func TestDuplicateSMSDoesNotProduceAnotherEvent(t *testing.T) {
	a := newAgent("unused")
	message := storedSMS{
		Index:  7,
		Memory: "SM",
		Message: smsMessage{
			Sender: "+8610010", Content: "测试短信", Timestamp: time.Now(), DeliveryID: "SM-7-test",
		},
	}
	a.mergeSMS([]storedSMS{message})
	firstEventRevision := a.eventRevision
	firstSMSRevision := a.smsRevision

	a.mergeSMS([]storedSMS{message})

	if a.eventRevision != firstEventRevision || a.smsRevision != firstSMSRevision {
		t.Fatalf(
			"重复短信错误地产生事件: event=%d->%d sms=%d->%d",
			firstEventRevision, a.eventRevision, firstSMSRevision, a.smsRevision,
		)
	}
}

func TestCallPollIntervalUsesURCAndActiveState(t *testing.T) {
	if got := callPollInterval(true, false); got != 30*time.Second {
		t.Fatalf("URC 空闲校准间隔=%s，期望 30s", got)
	}
	if got := callPollInterval(false, false); got != 5*time.Second {
		t.Fatalf("无 URC 空闲兜底间隔=%s，期望 5s", got)
	}
	if got := callPollInterval(true, true); got != 2*time.Second {
		t.Fatalf("通话期间校准间隔=%s，期望 2s", got)
	}
}

func TestATKeepaliveRetriesOnceAfterIdlePortTimeout(t *testing.T) {
	attempts := 0
	err := probeATWithRecovery(func(command string, timeout time.Duration) (string, error) {
		attempts++
		if command != "AT" {
			t.Fatalf("保活指令=%q，期望 AT", command)
		}
		if attempts == 1 {
			return "", errors.New("等待 AT 响应超时")
		}
		return "OK", nil
	})

	if err != nil {
		t.Fatalf("端口重开后的第二次探测应恢复: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("AT 恢复尝试次数=%d，期望 2", attempts)
	}
}

func TestATKeepaliveDoesNotRepeatHealthyProbe(t *testing.T) {
	attempts := 0
	err := probeATWithRecovery(func(command string, timeout time.Duration) (string, error) {
		attempts++
		return "OK", nil
	})

	if err != nil || attempts != 1 {
		t.Fatalf("健康 AT 探测不应重复: attempts=%d err=%v", attempts, err)
	}
}

func TestSMSNoticeOverflowRequestsFullRescan(t *testing.T) {
	a := newAgent("unused")
	for index := 0; index < cap(a.smsNotices); index++ {
		a.enqueueSMSNotice(smsStorageRef{Memory: "SM", Index: index})
	}
	a.enqueueSMSNotice(smsStorageRef{Memory: "SM", Index: 99})

	if !a.smsRescanRequested {
		t.Fatal("短信 URC 队列溢出后没有请求全量校准")
	}
}

func TestDebugLogBoundsPayloadAndEventCount(t *testing.T) {
	var log debugLog
	large := strings.Repeat("x", debugMaxPayload+100)
	for index := 0; index < debugMaxEvents+20; index++ {
		log.add("test", "rx", "event", large, nil)
	}
	events, latest, storedBytes := log.snapshot(0, debugMaxEvents)
	if len(events) == 0 || len(events) > debugMaxEvents {
		t.Fatalf("环形日志事件数=%d", len(events))
	}
	if latest != debugMaxEvents+20 || storedBytes > debugMaxStoredBytes {
		t.Fatalf("环形日志边界错误: latest=%d bytes=%d", latest, storedBytes)
	}
	if !strings.Contains(events[len(events)-1].Payload, "[truncated]") {
		t.Fatal("超长调试载荷未标记截断")
	}
}

func testLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

func TestNormalizeKnownEUICCAID(t *testing.T) {
	got, err := normalizeKnownEUICCAID("a06573746b6d65ffff4953442d522031")
	if err != nil || got != "A06573746B6D65FFFF4953442D522031" {
		t.Fatalf("eUICC 2 AID 规范化失败: got=%q err=%v", got, err)
	}
	if _, err := normalizeKnownEUICCAID("A000000001"); err == nil {
		t.Fatal("未验证的 AID 未被拒绝")
	}
}

func TestCGLAResponsePattern(t *testing.T) {
	response := `AT+CGLA=1,10,"80E2910000"` + "\r\n+CGLA: 4,\"9000\"\r\nOK"
	match := cglaResponsePattern.FindStringSubmatch(response)
	if len(match) != 2 || match[1] != "9000" {
		t.Fatalf("CGLA 响应解析错误: %#v", match)
	}
}

func TestPhysicalSIMESIMProbeError(t *testing.T) {
	err := errors.New("未发现任何 eUICC: 打开 eUICC logical channel 失败: AT 指令失败: ERROR")
	if !isPhysicalSIMESIMProbeError(err) {
		t.Fatal("实体 SIM 的 CCHO ERROR 应识别为卡片类型结果")
	}
	if isPhysicalSIMESIMProbeError(errors.New("读取 eUICC 超时")) {
		t.Fatal("普通通信错误不得误识别为实体 SIM")
	}
}

func TestProfilePayloadKeepsEUICCState(t *testing.T) {
	iccid, err := sgp22.NewICCID("8944305293607172968")
	if err != nil {
		t.Fatal(err)
	}
	payload := profilePayload(&sgp22.ProfileInfo{
		ICCID:               iccid,
		ProfileState:        sgp22.ProfileEnabled,
		ProfileNickname:     "CTExcel eSIM",
		ServiceProviderName: "CTExcel",
		ProfileClass:        sgp22.ProfileClassOperational,
	})
	if payload.ICCID != "8944305293607172968" || payload.State != 1 || payload.StateText != "已启用" {
		t.Fatalf("Profile 映射错误: %#v", payload)
	}
}

func TestParseVoicePCMStatsUsesLatestCompleteLine(t *testing.T) {
	logData := []byte(
		"mavo-pcm-bridge[stats]: uplink_bytes=320 uplink_frames=1 uplink_peak=12 downlink_bytes=640 downlink_frames=2 downlink_peak=34 downlink_dropped_frames=0\n" +
			"qdc507-agent[event]: time=2026-08-16T00:00:00Z still-running\n" +
			"mavo-pcm-bridge[stats]: uplink_bytes=960 uplink_frames=3 uplink_peak=1234 downlink_bytes=1280 downlink_frames=4 downlink_peak=2345 downlink_dropped_frames=2\n",
	)
	stats, ok := parseVoicePCMStats(logData)
	if !ok {
		t.Fatal("未解析到语音 PCM 统计")
	}
	if stats.UplinkBytes != 960 || stats.UplinkFrames != 3 || stats.UplinkPeak != 1234 {
		t.Fatalf("上行统计解析错误: %#v", stats)
	}
	if stats.DownlinkBytes != 1280 || stats.DownlinkFrames != 4 ||
		stats.DownlinkPeak != 2345 || stats.DownlinkDroppedFrame != 2 {
		t.Fatalf("下行统计解析错误: %#v", stats)
	}
}

func TestVoiceRouteMarkersRequireD4AndNetworkBridge(t *testing.T) {
	data := []byte("mavo-pcm-bridge[info]: network PCM listening on 192.168.225.1:7580\n" +
		"mavo-pcm-bridge[info]: network PCM client connected\n" +
		"mavo-pcm-bridge[info]: bridge active on 192.168.225.1:7580\n")
	if voiceRouteLogReady(data) {
		t.Fatal("缺少 D4 route session 的日志不应被判定为完整路由")
	}
	data = append(data, []byte("mavo-pcm-bridge[info]: VoLTE route session active on hw:0,4\n")...)
	if !voiceRouteLogReady(data) {
		t.Fatal("D4 route session 与网络桥标记齐全时应判定为完整路由")
	}
}

func TestVoiceRoutePhaseSeparatesListenerFromClient(t *testing.T) {
	listening := []byte("mavo-pcm-bridge[info]: VoLTE route session active on hw:0,4\n" +
		"mavo-pcm-bridge[info]: network PCM listening on 192.168.225.1:7580\n")
	if !voiceRouteListeningLogReady(listening) {
		t.Fatal("7580 listener marker should be independently observable")
	}
	if voiceRouteLogReady(listening) {
		t.Fatal("listener readiness must not be reported as a completed PCM handshake")
	}
	connected := append(listening,
		[]byte("mavo-pcm-bridge[info]: network PCM client connected\n"+
			"mavo-pcm-bridge[info]: bridge active on 192.168.225.1:7580\n")...)
	if !voiceRouteLogReady(connected) {
		t.Fatal("full route should be ready after handshake and worker startup")
	}
}

func TestVoiceListenerReadyTimeoutAllowsHelperStartup(t *testing.T) {
	// 这里只等待 helper 建立监听，不再等待未来才会执行的客户端连接。
	if voiceListenerReadyTimeout < 5*time.Second {
		t.Fatalf("网络 PCM 监听等待时间=%s，至少需要 5s", voiceListenerReadyTimeout)
	}
}

func TestVoiceRouteStartLeaseDoesNotBlockStateSnapshots(t *testing.T) {
	tracker := voiceTracker{}
	release, started := tracker.beginRouteStart(time.Now())
	if !started {
		t.Fatal("首次语音桥启动应取得生命周期租约")
	}
	defer release()

	done := make(chan voiceRouteSnapshot, 1)
	go func() { done <- tracker.snapshot() }()
	select {
	case snapshot := <-done:
		if !snapshot.Starting {
			t.Fatal("冷启动期间快照应显示 starting")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("语音桥冷启动不得阻塞状态和诊断查询")
	}
}

func TestVoiceRouteStartLeaseSerializesConcurrentStarts(t *testing.T) {
	tracker := voiceTracker{}
	release, started := tracker.beginRouteStart(time.Now())
	if !started {
		t.Fatal("首次语音桥启动应成功")
	}
	defer release()
	if _, duplicate := tracker.beginRouteStart(time.Now()); duplicate {
		t.Fatal("已有冷启动进行时不得再启动第二套 D4/D5/D6 路由")
	}
}

func TestStopVoiceRouteIsIdempotentWhileCleanupIsRunning(t *testing.T) {
	a := &agent{}
	a.voice.stopping = true

	a.stopVoiceRoute()

	a.voice.mu.Lock()
	stillStopping := a.voice.stopping
	a.voice.mu.Unlock()
	if !stillStopping {
		t.Fatal("并发的第二次语音清理不得接管或提前结束第一次清理")
	}
}

func TestSamsungStopVoiceRouteNeverTouchesQDC507Media(t *testing.T) {
	original := stopVoiceMediaRouteForLifecycle
	defer func() { stopVoiceMediaRouteForLifecycle = original }()
	stops := 0
	stopVoiceMediaRouteForLifecycle = func() { stops++ }

	withoutPCM := &agent{}
	withoutPCM.stopVoiceRoute()
	if stops != 0 {
		t.Fatalf("未启动 PCM 的拒接路径不应清理媒体，实际=%d", stops)
	}

	withPCM := &agent{voiceBackend: voiceBackendConfig{kind: voiceBackendSamsungAndroid}}
	withPCM.voice.mediaRouteStarted = true
	withPCM.stopVoiceRoute()
	if stops != 0 {
		t.Fatalf("三星 PCM 停止时不得执行 QDC507 媒体清理，实际=%d", stops)
	}
	if withPCM.voice.mediaRouteStarted {
		t.Fatal("清理后 mediaRouteStarted 必须复位")
	}
}

func TestModuleUpdateModeAllowsSignedRepairAndDowngrade(t *testing.T) {
	if shouldInstallModuleVersion("0.3.38", "0.3.38", "normal") {
		t.Fatal("normal mode must not reinstall the same version")
	}
	if !shouldInstallModuleVersion("0.3.38", "0.3.38", "repair") {
		t.Fatal("repair mode must reinstall the same version")
	}
	if !shouldInstallModuleVersion("0.3.38", "0.3.37", "repair") {
		t.Fatal("explicit repair mode must allow a signed downgrade")
	}
	if shouldInstallModuleVersion("0.3.38", "0.3.37", "normal") {
		t.Fatal("automatic normal mode must not downgrade")
	}
}

func TestModuleUpdateDeltaStagesOnlyChangedPayloads(t *testing.T) {
	root := t.TempDir()
	matching := []byte("already-installed")
	changed := []byte("old-runtime")
	matchingDigest := sha256.Sum256(matching)
	newDigest := sha256.Sum256([]byte("new-runtime"))
	manifest := moduleUpdateManifest{Files: []moduleUpdateFile{
		{Name: "matching", Target: "bin/matching", SHA256: hex.EncodeToString(matchingDigest[:]), Size: int64(len(matching))},
		{Name: "changed", Target: "bin/changed", SHA256: hex.EncodeToString(newDigest[:]), Size: 11},
		{Name: "missing", Target: "bin/missing", SHA256: strings.Repeat("a", 64), Size: 7},
	}}
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/matching"), matching, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/changed"), changed, 0o600); err != nil {
		t.Fatal(err)
	}

	files, err := moduleUpdateFilesRequiringReplacement(manifest, root)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0].Name != "changed" || files[1].Name != "missing" {
		t.Fatalf("delta files=%+v, want changed and missing only", files)
	}
}

func TestModuleUpdateStateUsesStableWireFields(t *testing.T) {
	encoded, err := json.Marshal(moduleUpdateState{
		OperationID: "update-1", Mode: "repair", Phase: "installing",
		InstalledVersion: "0.3.38", TargetVersion: "0.3.39",
		Progress: 55, Message: "正在安装", UpdatedAt: time.Unix(1, 0).UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		`"operation_id":"update-1"`, `"mode":"repair"`,
		`"phase":"installing"`, `"installed_version":"0.3.38"`,
		`"target_version":"0.3.39"`, `"progress":55`,
	} {
		if !strings.Contains(string(encoded), field) {
			t.Fatalf("missing %s in %s", field, encoded)
		}
	}
}

func TestModuleUpdateLogOmitsEmptyErrorField(t *testing.T) {
	success := formatModuleUpdateLogLine("completed", 100, "新 Agent 健康检查通过", "")
	if strings.Contains(success, "error=") {
		t.Fatalf("成功日志不应包含空 error 字段：%q", success)
	}
	failure := formatModuleUpdateLogLine("failed", 100, "安装失败", "no space left on device")
	if !strings.Contains(failure, "error=no space left on device") {
		t.Fatalf("失败日志必须保留真实错误：%q", failure)
	}
}

func TestModuleUpdateCompletionRecoversAfterStartupRemovedPendingMarker(t *testing.T) {
	state := moduleUpdateState{
		OperationID:      "update-restart-race",
		Mode:             "repair",
		Phase:            "restarting",
		InstalledVersion: "0.3.41",
		TargetVersion:    "0.3.42",
		Progress:         80,
		Message:          "Agent 已安装，正在安全重启",
	}

	completed, ok := completedModuleUpdateState(state, "0.3.42", false)
	if !ok {
		t.Fatal("新 Agent 已健康运行且版本匹配时，即使启动脚本先清除了 pending 标记也应完成安装状态")
	}
	if completed.Phase != "completed" || completed.Progress != 100 {
		t.Fatalf("完成状态=%+v，期望 completed/100", completed)
	}
}

func TestModuleUpdateCompletionWaitsForStartupToRemovePendingMarker(t *testing.T) {
	state := moduleUpdateState{
		OperationID:      "update-still-starting",
		Mode:             "repair",
		Phase:            "restarting",
		InstalledVersion: "0.3.39",
		TargetVersion:    "0.3.43",
		Progress:         80,
		Message:          "Agent 已安装，正在安全重启",
	}

	if _, ok := completedModuleUpdateState(state, "0.3.43", true); ok {
		t.Fatal("启动脚本仍保留 pending 回滚标记时，不能仅凭版本号误报安装完成")
	}
}

func TestModuleUpdateCompletionDoesNotConfirmDifferentRunningVersion(t *testing.T) {
	state := moduleUpdateState{
		OperationID:   "update-rollback",
		Phase:         "restarting",
		TargetVersion: "0.3.42",
		Progress:      80,
	}

	if _, ok := completedModuleUpdateState(state, "0.3.41", false); ok {
		t.Fatal("运行中的 Agent 版本与目标版本不一致时不能误报安装完成")
	}
}

func TestCleanupStaleModuleUpdateArtifactsPreservesPendingRollback(t *testing.T) {
	root := t.TempDir()
	temporaryRoot := filepath.Join(root, "tmp")
	dataRoot := filepath.Join(root, "djonehub")
	backupRoot := filepath.Join(dataRoot, "backup")
	for _, path := range []string{
		temporaryRoot,
		backupRoot,
		filepath.Join(dataRoot, ".update-stage-stale"),
		filepath.Join(backupRoot, "app-update-stale"),
		filepath.Join(backupRoot, "app-update-pending"),
	} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	staleUpload := filepath.Join(temporaryRoot, "djonehub-update-stale.tar.gz")
	if err := os.WriteFile(staleUpload, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(dataRoot, "update-pending")
	pending := filepath.Join(backupRoot, "app-update-pending")
	if err := os.WriteFile(marker, []byte(pending+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := cleanupStaleModuleUpdateArtifacts(dataRoot, temporaryRoot, marker); err != nil {
		t.Fatal(err)
	}

	for _, removed := range []string{
		staleUpload,
		filepath.Join(dataRoot, ".update-stage-stale"),
		filepath.Join(backupRoot, "app-update-stale"),
	} {
		if _, err := os.Stat(removed); !os.IsNotExist(err) {
			t.Fatalf("expected stale artifact to be removed: %s", removed)
		}
	}
	if _, err := os.Stat(pending); err != nil {
		t.Fatalf("pending rollback must be preserved: %v", err)
	}
}

func TestLifecyclePhaseForModemState(t *testing.T) {
	tests := map[string]string{
		"incoming": "ringing",
		"waiting":  "ringing",
		"dialing":  "connecting",
		"alerting": "connecting",
		"active":   "active",
		"held":     "active",
		"idle":     "",
	}
	for state, want := range tests {
		if got := lifecyclePhaseForModemState(state); got != want {
			t.Errorf("state=%s phase=%s, want %s", state, got, want)
		}
	}
}
