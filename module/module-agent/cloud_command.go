package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var cloudCommandIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,36}$`)

type cloudCommandCall struct {
	CallID         string `json:"call_id"`
	CallUUID       string `json:"call_uuid"`
	Generation     uint64 `json:"generation,omitempty"`
	CallSecret     string `json:"call_secret"`
	RelayURL       string `json:"relay_url"`
	Direction      string `json:"direction"`
	MediaTransport string `json:"media_transport,omitempty"`
}

type cloudDeviceCommand struct {
	CommandID string            `json:"command_id"`
	Type      string            `json:"type"`
	Action    string            `json:"action,omitempty"`
	TraceID   string            `json:"trace_id,omitempty"`
	Owner     string            `json:"owner,omitempty"`
	ExpiresAt string            `json:"expires_at"`
	Number    string            `json:"number"`
	Message   string            `json:"message,omitempty"`
	Call      *cloudCommandCall `json:"call,omitempty"`
}

type cloudCommandResult struct {
	CommandID string         `json:"command_id"`
	Status    string         `json:"status"`
	Result    map[string]any `json:"result,omitempty"`
	Error     string         `json:"error,omitempty"`
}

func cloudCommandURL(registration pushRegistration) (string, error) {
	relay, err := url.Parse(strings.TrimSpace(registration.RelayURL))
	if err != nil || relay.Scheme != "https" || relay.Host == "" || relay.User != nil {
		return "", errors.New("公网命令必须使用无凭据 HTTPS Relay")
	}
	if registration.DeviceID == "" || registration.DeviceSecret == "" {
		return "", errors.New("公网命令设备身份无效")
	}
	relay.Scheme = "wss"
	relay.Path = "/v1/devices/" + url.PathEscape(registration.DeviceID) + "/commands/connect"
	relay.RawQuery = ""
	return relay.String(), nil
}

func (a *agent) cloudCommandLoop() {
	for {
		registration, ready := a.push.commandRegistration()
		if !ready {
			time.Sleep(3 * time.Second)
			continue
		}
		endpoint, err := cloudCommandURL(registration)
		if err != nil {
			a.debug.add("cloud-command", "error", "公网命令地址无效", err.Error(), nil)
			time.Sleep(5 * time.Second)
			continue
		}
		if err := a.syncCloudCommandsOnce(); err != nil {
			a.debug.add("cloud-command", "pull_failed", "WebSocket 建连前拉取待处理命令失败", err.Error(), nil)
		}
		ctx, cancel := context.WithCancel(context.Background())
		socket, err := dialCloudWebSocketAuthorized(ctx, endpoint, registration.DeviceSecret)
		if err != nil {
			cancel()
			a.debug.add("cloud-command", "error", "连接公网命令通道失败", err.Error(), nil)
			time.Sleep(3 * time.Second)
			continue
		}
		a.debug.add("cloud-command", "event", "公网拨号与短信通道已连接", "", nil)
		a.serveCloudCommands(ctx, socket)
		_ = socket.Close()
		cancel()
		time.Sleep(time.Second)
	}
}

func (a *agent) syncCloudCommandsOnce() error {
	commands, err := a.push.pullCommands()
	if err != nil {
		return err
	}
	for _, command := range commands {
		result := a.executeCloudCommand(command)
		if err := a.push.completeCommand(result); err != nil {
			return fmt.Errorf("回写命令 %s 结果失败: %w", command.CommandID, err)
		}
	}
	return nil
}

func (a *agent) serveCloudCommands(ctx context.Context, socket *cloudWebSocket) {
	keepaliveDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(20 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-keepaliveDone:
				return
			case <-ticker.C:
				if err := socket.writeMessage(cloudOpcodePing, []byte("command-keepalive")); err != nil {
					_ = socket.Close()
					return
				}
			}
		}
	}()
	defer close(keepaliveDone)
	for ctx.Err() == nil {
		opcode, payload, err := socket.ReadMessage()
		if err != nil {
			return
		}
		if opcode != cloudOpcodeText {
			continue
		}
		var command cloudDeviceCommand
		if err := json.Unmarshal(payload, &command); err != nil {
			continue
		}
		result := a.executeCloudCommand(command)
		encoded, _ := json.Marshal(result)
		if err := socket.WriteText(encoded); err != nil {
			return
		}
	}
}

func (a *agent) executeCloudCommand(command cloudDeviceCommand) cloudCommandResult {
	a.cloudCommandExecMu.Lock()
	defer a.cloudCommandExecMu.Unlock()
	if !cloudCommandIDPattern.MatchString(command.CommandID) {
		return cloudCommandResult{CommandID: command.CommandID, Status: "failed", Error: "云端命令 ID 无效"}
	}
	if result, exists := a.cachedCloudCommandResult(command.CommandID); exists {
		return result
	}

	if expiry, err := time.Parse(time.RFC3339Nano, command.ExpiresAt); err != nil || time.Now().After(expiry) {
		return a.rememberCloudCommandResult(cloudCommandResult{
			CommandID: command.CommandID, Status: "failed", Error: "云端命令已过期",
		})
	}
	result := cloudCommandResult{CommandID: command.CommandID, Status: "completed"}
	switch command.Type {
	case "dial":
		value, err := a.dialNumber(command.Number)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = value
		if command.Call == nil || command.Call.Direction != "outgoing" {
			result.Status, result.Error = "failed", "公网呼出媒体凭据缺失"
			break
		}
		a.startCloudCall(cloudCallDescriptor{
			CallID: command.Call.CallID, CallUUID: command.Call.CallUUID,
			Generation: command.Call.Generation,
			CallSecret: command.Call.CallSecret, RelayURL: command.Call.RelayURL,
			Direction: "outgoing", MediaTransport: command.Call.MediaTransport, StartedAt: time.Now(),
		})
	case "send_sms":
		segments, err := a.sendSMSMessage(command.Number, command.Message)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = map[string]any{"sent": true, "segments": segments}
	case "dtmf":
		if err := a.sendDTMFDigit(command.Number); err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		result.Result = map[string]any{"sent": true}
	case "call_control":
		descriptor, err := a.validateCloudCallCommand(command)
		if err != nil {
			result.Status, result.Error = "failed", err.Error()
			break
		}
		fields := cloudCallTraceFields(descriptor, cloudCallAction{
			Action: command.Action, CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
			Generation: descriptor.Generation, CommandID: command.CommandID,
			TraceID: command.TraceID, Owner: command.Owner,
		})
		a.debug.add("cloud-call-control", "received", "独立控制通道收到通话命令", "", fields)
		if a.profile.AndroidTelecom {
			androidAction := command.Action
			if androidAction == "rescue_hangup" {
				androidAction = "end"
			}
			androidResult := a.executeAndroidCallCommand(command.CommandID, androidAction)
			if !androidResult.Success {
				result.Status, result.Error = "failed", androidResult.Error
				a.debug.add("cloud-call-control", "failed", "Android Telecom 命令失败", androidResult.Error, fields)
				break
			}
			switch command.Action {
			case "answer":
				result.Result = map[string]any{"answered": true, "android_confirmed": true}
			case "end", "reject", "rescue_hangup":
				result.Result = map[string]any{"ended": true, "android_confirmed": true}
				a.retireCloudCallDescriptor(descriptor)
				if a.push != nil {
					go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, command.Owner, "ended") }()
				}
			default:
				result.Status, result.Error = "failed", "不支持的公网通话控制动作"
			}
			break
		}
		switch command.Action {
		case "end", "reject", "rescue_hangup":
			a.debug.add("cloud-call-control", "modem_executing", "执行挂断并确认基带状态", "ATH（失败时回退 AT+CHUP）→ AT+CLCC", fields)
			attempts, lastCLCC, hangupErr := a.hangupCallConfirmed()
			if hangupErr != nil {
				result.Status, result.Error = "failed", hangupErr.Error()
				a.debug.add("cloud-call-control", "failed", "独立通道挂断未获 CLCC 确认", hangupErr.Error(), fields)
				break
			}
			fields["clcc_attempts"] = fmt.Sprintf("%d", attempts)
			result.Result = map[string]any{
				"ended": true, "modem_confirmed": true,
				"clcc_attempts": attempts, "last_clcc": lastCLCC,
			}
			a.debug.add("cloud-call-control", "completed", "独立通道挂断已由 CLCC 确认", lastCLCC, fields)
			a.retireCloudCallDescriptor(descriptor)
			if a.push != nil {
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, command.Owner, "ended") }()
			}
		case "answer":
			if err := a.answerCall(); err != nil {
				result.Status, result.Error = "failed", err.Error()
				break
			}
			result.Result = map[string]any{"answered": true}
		default:
			result.Status, result.Error = "failed", "不支持的公网通话控制动作"
		}
	default:
		result.Status, result.Error = "failed", fmt.Sprintf("不支持的云端命令: %s", command.Type)
	}
	return a.rememberCloudCommandResult(result)
}

func (a *agent) executeAndroidCallCommand(commandID, action string) androidCommandResult {
	return a.executeAndroidCallCommandWithNumber(commandID, action, "")
}

func (a *agent) executeAndroidCallCommandWithNumber(commandID, action, number string) androidCommandResult {
	switch action {
	case "answer", "reject", "end", "dtmf":
	default:
		return androidCommandResult{ID: commandID, Error: "unsupported Android Telecom action"}
	}
	a.mu.RLock()
	callID := ""
	if a.calls.Active != nil {
		callID = a.calls.Active.AndroidID
	}
	a.mu.RUnlock()
	if callID == "" {
		return androidCommandResult{ID: commandID, Error: "Android Telecom active call unavailable"}
	}
	result := a.android.execute(context.Background(), androidCommand{
		ID: commandID, Action: action, CallID: callID, Number: number,
	}, 12*time.Second)
	if action == "answer" && result.Success {
		if err := a.waitForAndroidCallState(callID, "active", 8*time.Second); err != nil {
			result.Success = false
			result.Error = err.Error()
		}
	}
	return result
}

func (a *agent) waitForAndroidCallState(androidCallID, expectedState string, timeout time.Duration) error {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		a.mu.RLock()
		active := a.calls.Active
		changed := a.callChanged
		if active != nil && active.AndroidID == androidCallID && active.State == expectedState {
			a.mu.RUnlock()
			return nil
		}
		callStillExists := active != nil && active.AndroidID == androidCallID
		a.mu.RUnlock()
		if !callStillExists {
			return errors.New("Android Telecom 通话在状态确认前已经结束")
		}
		select {
		case <-changed:
		case <-timer.C:
			return fmt.Errorf("Android Telecom 未确认通话状态 %s", expectedState)
		}
	}
}

func (a *agent) cachedCloudCommandResult(commandID string) (cloudCommandResult, bool) {
	a.cloudCommandMu.Lock()
	defer a.cloudCommandMu.Unlock()
	result, exists := a.cloudCommandResults[commandID]
	if !exists {
		return cloudCommandResult{}, false
	}
	if expiry, ok := a.cloudCommandExpiry[commandID]; !ok || !expiry.After(time.Now()) {
		delete(a.cloudCommandResults, commandID)
		delete(a.cloudCommandExpiry, commandID)
		return cloudCommandResult{}, false
	}
	return result, true
}

func (a *agent) validateCloudCallCommand(command cloudDeviceCommand) (cloudCallDescriptor, error) {
	if command.Call == nil {
		return cloudCallDescriptor{}, errors.New("公网通话控制缺少通话身份")
	}
	current, ok := a.currentCloudCallDescriptor()
	if !ok {
		return cloudCallDescriptor{}, errors.New("当前没有可控制的公网通话")
	}
	if command.Call.CallID != current.CallID ||
		!strings.EqualFold(command.Call.CallUUID, current.CallUUID) {
		return cloudCallDescriptor{}, errors.New("公网通话控制不属于当前通话")
	}
	expectedGeneration := current.Generation
	if expectedGeneration == 0 {
		expectedGeneration = 1
	}
	generation := command.Call.Generation
	if generation == 0 {
		generation = 1
	}
	if generation != expectedGeneration {
		return cloudCallDescriptor{}, errors.New("公网通话控制 generation 已过期")
	}
	if command.Owner != "iphone" && command.Owner != "watch" {
		return cloudCallDescriptor{}, errors.New("公网通话控制 owner 无效")
	}
	if len(command.TraceID) > 128 {
		return cloudCallDescriptor{}, errors.New("公网通话控制 trace_id 过长")
	}
	return current, nil
}

func (a *agent) rememberCloudCommandResult(result cloudCommandResult) cloudCommandResult {
	a.cloudCommandMu.Lock()
	defer a.cloudCommandMu.Unlock()
	if a.cloudCommandResults == nil {
		a.cloudCommandResults = make(map[string]cloudCommandResult)
	}
	if a.cloudCommandExpiry == nil {
		a.cloudCommandExpiry = make(map[string]time.Time)
	}
	now := time.Now()
	for commandID, expiry := range a.cloudCommandExpiry {
		if !expiry.After(now) {
			delete(a.cloudCommandExpiry, commandID)
			delete(a.cloudCommandResults, commandID)
		}
	}
	if len(a.cloudCommandResults) >= 256 {
		oldestID := ""
		oldestExpiry := time.Time{}
		for commandID, expiry := range a.cloudCommandExpiry {
			if oldestID == "" || expiry.Before(oldestExpiry) {
				oldestID, oldestExpiry = commandID, expiry
			}
		}
		if oldestID != "" {
			delete(a.cloudCommandExpiry, oldestID)
			delete(a.cloudCommandResults, oldestID)
		}
	}
	a.cloudCommandResults[result.CommandID] = result
	a.cloudCommandExpiry[result.CommandID] = now.Add(10 * time.Minute)
	return result
}
