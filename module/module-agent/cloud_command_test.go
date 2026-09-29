package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestHangupConfirmationWaitsForFreshCLCCIdle(t *testing.T) {
	commands := []string{}
	responses := []string{
		"OK",
		`+CLCC: 1,0,0,0,0,"10086",129\r\nOK`,
		"OK",
	}
	runner := func(command string, _ time.Duration) (string, error) {
		commands = append(commands, command)
		response := responses[0]
		responses = responses[1:]
		return response, nil
	}
	attempts, lastCLCC, err := hangupAndConfirmCall(
		runner,
		func(time.Duration) {},
		[]time.Duration{time.Millisecond, time.Millisecond},
	)
	if err != nil {
		t.Fatal(err)
	}
	if attempts != 2 || lastCLCC != "OK" {
		t.Fatalf("确认结果 attempts=%d last=%q", attempts, lastCLCC)
	}
	want := []string{"ATH", "AT+CLCC", "AT+CLCC"}
	if strings.Join(commands, ",") != strings.Join(want, ",") {
		t.Fatalf("命令链=%v，期望=%v", commands, want)
	}
}

func TestHangupConfirmationFallsBackToCHUPAndRejectsPersistentCall(t *testing.T) {
	commands := []string{}
	runner := func(command string, _ time.Duration) (string, error) {
		commands = append(commands, command)
		switch command {
		case "ATH":
			return "ERROR", errors.New("ATH unsupported")
		case "AT+CHUP":
			return "OK", nil
		default:
			return `+CLCC: 1,0,0,0,0,"10086",129\r\nOK`, nil
		}
	}
	attempts, lastCLCC, err := hangupAndConfirmCall(
		runner,
		func(time.Duration) {},
		[]time.Duration{time.Millisecond, time.Millisecond, time.Millisecond},
	)
	if err == nil || !strings.Contains(err.Error(), "CLCC") {
		t.Fatalf("持续通话必须失败，err=%v", err)
	}
	if attempts != 3 || !strings.Contains(lastCLCC, "+CLCC:") {
		t.Fatalf("失败证据 attempts=%d last=%q", attempts, lastCLCC)
	}
	if len(commands) < 2 || commands[0] != "ATH" || commands[1] != "AT+CHUP" {
		t.Fatalf("未执行 ATH -> AT+CHUP 回退：%v", commands)
	}
}

func TestCloudHangupCommandIsConfirmedAndIdempotent(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 7, Direction: "incoming",
	}
	atCalls := 0
	agent := &agent{
		cloudCommandResults: make(map[string]cloudCommandResult),
		cloudCallCurrent:    &descriptor,
		callControlCommand: func(command string, _ time.Duration) (string, error) {
			atCalls++
			return "OK", nil
		},
		callControlSleep:  func(time.Duration) {},
		callControlDelays: []time.Duration{time.Millisecond},
	}
	command := cloudDeviceCommand{
		CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
		Type:      "call_control", Action: "end", Owner: "iphone", TraceID: "9f9dc60b",
		ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
		Call: &cloudCommandCall{
			CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
			Generation: descriptor.Generation, Direction: descriptor.Direction,
		},
	}
	first := agent.executeCloudCommand(command)
	second := agent.executeCloudCommand(command)
	if first.Status != "completed" || first.Result["modem_confirmed"] != true {
		t.Fatalf("首次结果=%#v", first)
	}
	if second.Status != first.Status || second.Result["modem_confirmed"] != true {
		t.Fatalf("重放结果不一致：first=%#v second=%#v", first, second)
	}
	if atCalls != 2 {
		t.Fatalf("同一 command_id 应只执行一次 ATH + CLCC，实际 AT 次数=%d", atCalls)
	}
}

func TestCloudHangupCommandRejectsStaleGenerationBeforeAT(t *testing.T) {
	for index, action := range []string{"end", "rescue_hangup"} {
		t.Run(action, func(t *testing.T) {
			descriptor := cloudCallDescriptor{
				CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
				Generation: 8, Direction: "incoming",
			}
			atCalls := 0
			agent := &agent{
				cloudCommandResults: make(map[string]cloudCommandResult),
				cloudCallCurrent:    &descriptor,
				callControlCommand: func(command string, _ time.Duration) (string, error) {
					atCalls++
					return "OK", nil
				},
			}
			result := agent.executeCloudCommand(cloudDeviceCommand{
				CommandID: fmt.Sprintf("9f9dc60b-3a36-4a0a-b87a-63a3ffb2714%d", index),
				Type:      "call_control", Action: action, Owner: "iphone",
				ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
				Call: &cloudCommandCall{
					CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
					Generation: 7, Direction: descriptor.Direction,
				},
			})
			if result.Status != "failed" || !strings.Contains(result.Error, "generation") {
				t.Fatalf("旧代次结果=%#v", result)
			}
			if atCalls != 0 {
				t.Fatalf("旧 generation 不得执行 AT，实际=%d", atCalls)
			}
		})
	}
}

func TestExpiredCloudCommandCacheEntryDoesNotMaskFreshExecution(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 7, Direction: "incoming",
	}
	commandID := "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145"
	atCalls := 0
	agent := &agent{
		cloudCommandResults: map[string]cloudCommandResult{
			commandID: {CommandID: commandID, Status: "failed", Error: "旧结果"},
		},
		cloudCommandExpiry: map[string]time.Time{commandID: time.Now().Add(-time.Second)},
		cloudCallCurrent:   &descriptor,
		callControlCommand: func(command string, _ time.Duration) (string, error) {
			atCalls++
			return "OK", nil
		},
		callControlSleep:  func(time.Duration) {},
		callControlDelays: []time.Duration{time.Millisecond},
	}
	result := agent.executeCloudCommand(cloudDeviceCommand{
		CommandID: commandID,
		Type:      "call_control", Action: "end", Owner: "iphone",
		ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
		Call: &cloudCommandCall{
			CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
			Generation: descriptor.Generation, Direction: descriptor.Direction,
		},
	})
	if result.Status != "completed" || result.Result["modem_confirmed"] != true {
		t.Fatalf("过期缓存未被替换：%#v", result)
	}
	if atCalls != 2 {
		t.Fatalf("过期缓存后应重新执行 ATH + CLCC，实际 AT 次数=%d", atCalls)
	}
}

func TestHeartbeatPullExecutesRescueAndPostsFinalResult(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 7, Direction: "incoming",
	}
	commandID := "a1a2a3a4-b5b6-47c8-89d0-e1e2e3e4e5e6"
	requests := []string{}
	var requestMu sync.Mutex
	var completion cloudCommandResult
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		// Hangup also asynchronously notifies call ownership. It is independent
		// of the command pull/complete ordering this test verifies.
		if request.URL.Path == "/v1/events/call-owner" {
			response.WriteHeader(http.StatusAccepted)
			return
		}
		requestMu.Lock()
		defer requestMu.Unlock()
		requests = append(requests, request.URL.Path)
		switch request.URL.Path {
		case "/v1/commands/pull":
			_ = json.NewEncoder(response).Encode(map[string]any{"commands": []cloudDeviceCommand{{
				CommandID: commandID, Type: "call_control", Action: "rescue_hangup",
				Owner: "iphone", TraceID: "trace-rescue",
				ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
				Call: &cloudCommandCall{
					CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
					Generation: descriptor.Generation, Direction: descriptor.Direction,
				},
			}}})
		case "/v1/commands/complete":
			var body struct {
				DeviceID     string `json:"device_id"`
				DeviceSecret string `json:"device_secret"`
				cloudCommandResult
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			if body.DeviceID == "" || body.DeviceSecret == "" {
				t.Fatal("命令完成回写缺少设备凭据")
			}
			completion = body.cloudCommandResult
			response.WriteHeader(http.StatusAccepted)
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	agent := &agent{
		push:                newPushManager(filepath.Join(t.TempDir(), "push.json")),
		cloudCommandResults: make(map[string]cloudCommandResult),
		cloudCommandExpiry:  make(map[string]time.Time),
		cloudCallCurrent:    &descriptor,
		callControlCommand: func(string, time.Duration) (string, error) {
			return "OK", nil
		},
		callControlSleep:  func(time.Duration) {},
		callControlDelays: []time.Duration{time.Millisecond},
	}
	agent.push.client = server.Client()
	agent.push.config = testPushRegistration(server.URL)

	if err := agent.syncCloudCommandsOnce(); err != nil {
		t.Fatal(err)
	}
	requestMu.Lock()
	defer requestMu.Unlock()
	if strings.Join(requests, ",") != "/v1/commands/pull,/v1/commands/complete" {
		t.Fatalf("HTTP 补漏链路=%v", requests)
	}
	if completion.CommandID != commandID || completion.Status != "completed" ||
		completion.Result["modem_confirmed"] != true {
		t.Fatalf("救援完成回写=%#v", completion)
	}
}

func TestConfirmedHangupRetiresDescriptorBeforeARescueCanTargetIt(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 7, Direction: "incoming",
	}
	atCalls := 0
	agent := &agent{
		cloudCommandResults: make(map[string]cloudCommandResult),
		cloudCommandExpiry:  make(map[string]time.Time),
		cloudCallCurrent:    &descriptor,
		callControlCommand: func(string, time.Duration) (string, error) {
			atCalls++
			return "OK", nil
		},
		callControlSleep:  func(time.Duration) {},
		callControlDelays: []time.Duration{time.Millisecond},
	}
	base := cloudDeviceCommand{
		Type: "call_control", Owner: "iphone", TraceID: "trace-rescue",
		ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
		Call: &cloudCommandCall{
			CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
			Generation: descriptor.Generation, Direction: descriptor.Direction,
		},
	}
	base.CommandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145"
	base.Action = "end"
	if result := agent.executeCloudCommand(base); result.Status != "completed" {
		t.Fatalf("原挂断失败: %#v", result)
	}
	base.CommandID = "a1a2a3a4-b5b6-47c8-89d0-e1e2e3e4e5e6"
	base.Action = "rescue_hangup"
	rescue := agent.executeCloudCommand(base)
	if rescue.Status != "failed" || !strings.Contains(rescue.Error, "没有可控制") {
		t.Fatalf("已结束通话的救援必须被拒绝: %#v", rescue)
	}
	if atCalls != 2 {
		t.Fatalf("救援不得再次执行 AT，实际=%d", atCalls)
	}
}
