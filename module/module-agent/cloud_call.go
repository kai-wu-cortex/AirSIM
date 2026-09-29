package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type cloudCallDescriptor struct {
	CallID         string
	CallUUID       string
	Generation     uint64
	CallSecret     string
	RelayURL       string
	Direction      string
	MediaTransport string
	StartedAt      time.Time
}

func cloudMediaURL(relayURL, callUUID, callSecret string) (string, error) {
	relay, err := url.Parse(strings.TrimSpace(relayURL))
	if err != nil || relay.Scheme != "https" || relay.Host == "" || relay.User != nil {
		return "", errors.New("公网媒体必须使用无凭据 HTTPS Relay")
	}
	if strings.TrimSpace(callUUID) == "" || len(callSecret) < 24 {
		return "", errors.New("通话媒体身份无效")
	}
	relay.Scheme = "wss"
	relay.Path = "/v1/calls/" + strings.ToLower(callUUID) + "/connect"
	relay.RawQuery = url.Values{"role": {"agent"}, "token": {callSecret}}.Encode()
	return relay.String(), nil
}

type cloudCallAction struct {
	Action        string `json:"action"`
	CallID        string `json:"call_id"`
	CallUUID      string `json:"call_uuid,omitempty"`
	Generation    uint64 `json:"generation,omitempty"`
	CommandID     string `json:"command_id,omitempty"`
	TraceID       string `json:"trace_id,omitempty"`
	Owner         string `json:"owner"`
	MediaProtocol string `json:"media_protocol,omitempty"`
}

func decodeCloudCallAction(data []byte, expectedCallID string) (cloudCallAction, error) {
	return decodeCloudCallActionForDescriptor(data, cloudCallDescriptor{
		CallID: expectedCallID, Generation: 1,
	})
}

func decodeCloudCallActionForDescriptor(data []byte, descriptor cloudCallDescriptor) (cloudCallAction, error) {
	var value cloudCallAction
	if err := json.Unmarshal(data, &value); err != nil {
		return cloudCallAction{}, err
	}
	if value.CallID == "" || value.CallID != descriptor.CallID {
		return cloudCallAction{}, fmt.Errorf("公网控制不属于当前通话")
	}
	if value.CallUUID != "" && descriptor.CallUUID != "" &&
		!strings.EqualFold(value.CallUUID, descriptor.CallUUID) {
		return cloudCallAction{}, fmt.Errorf("公网控制的 call_uuid 不属于当前通话")
	}
	expectedGeneration := descriptor.Generation
	if expectedGeneration == 0 {
		expectedGeneration = 1
	}
	if value.Generation == 0 {
		value.Generation = expectedGeneration
	} else if value.Generation != expectedGeneration {
		return cloudCallAction{}, fmt.Errorf("公网控制的 generation 已过期")
	}
	if value.CommandID != "" && !cloudCommandIDPattern.MatchString(value.CommandID) {
		return cloudCallAction{}, fmt.Errorf("公网控制 command_id 无效")
	}
	if len(value.TraceID) > 128 {
		return cloudCallAction{}, fmt.Errorf("公网控制 trace_id 过长")
	}
	// 兼容已经建立的旧 Watch Relay 会话；新版 Relay 会用已认证的 WebSocket 角色覆盖 owner。
	if value.Owner == "" {
		value.Owner = "watch"
	}
	if value.Owner != "watch" && value.Owner != "iphone" {
		return cloudCallAction{}, errors.New("公网通话媒体所有者无效")
	}
	switch value.Action {
	case "answer", "reject", "end":
		return value, nil
	default:
		return cloudCallAction{}, errors.New("不支持的公网通话动作")
	}
}

func cloudCallTraceFields(descriptor cloudCallDescriptor, action cloudCallAction) map[string]string {
	generation := descriptor.Generation
	if generation == 0 {
		generation = 1
	}
	fields := map[string]string{
		"call_id": descriptor.CallID, "call_uuid": strings.ToLower(descriptor.CallUUID),
		"generation": fmt.Sprintf("%d", generation),
		"media_transport": resolveCloudMediaTransport(
			descriptor.MediaTransport,
			[]string{cloudMediaTransportLegacyPCM},
			false,
		),
	}
	if action.Action != "" {
		fields["action"] = action.Action
	}
	if action.CommandID != "" {
		fields["command_id"] = strings.ToLower(action.CommandID)
	}
	if action.TraceID != "" {
		fields["trace_id"] = action.TraceID
	}
	if action.Owner != "" {
		fields["owner"] = action.Owner
	}
	if action.MediaProtocol != "" {
		fields["media_protocol"] = normalizedCloudPCMProtocol(action.MediaProtocol)
	}
	return fields
}

func cloudStatusForAction(status, message string, descriptor cloudCallDescriptor, action cloudCallAction) []byte {
	generation := descriptor.Generation
	if generation == 0 {
		generation = 1
	}
	value := map[string]any{
		"status": status, "call_id": descriptor.CallID,
		"call_uuid": strings.ToLower(descriptor.CallUUID), "generation": generation,
	}
	if action.Action != "" {
		value["action"] = action.Action
	}
	if action.CommandID != "" {
		value["command_id"] = strings.ToLower(action.CommandID)
	}
	if action.TraceID != "" {
		value["trace_id"] = action.TraceID
	}
	if protocol := normalizedCloudPCMProtocol(action.MediaProtocol); protocol != "" {
		value["media_protocol"] = protocol
	}
	if message != "" {
		value["message"] = message
	}
	data, _ := json.Marshal(value)
	return data
}

func (a *agent) startCloudCall(descriptor cloudCallDescriptor) {
	if descriptor.Generation == 0 {
		descriptor.Generation = 1
	}
	if descriptor.StartedAt.IsZero() {
		descriptor.StartedAt = time.Now()
	}
	a.cloudCallMu.Lock()
	if a.cloudCallCancel != nil {
		a.cloudCallCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.cloudCallCancel = cancel
	current := descriptor
	a.cloudCallCurrent = &current
	a.cloudCallMu.Unlock()
	go a.runCloudCall(ctx, descriptor)
}

func (a *agent) currentCloudCallDescriptor() (cloudCallDescriptor, bool) {
	a.cloudCallMu.Lock()
	defer a.cloudCallMu.Unlock()
	if a.cloudCallCurrent == nil {
		return cloudCallDescriptor{}, false
	}
	return *a.cloudCallCurrent, true
}

func (a *agent) retireCloudCallDescriptor(descriptor cloudCallDescriptor) {
	a.cloudCallMu.Lock()
	defer a.cloudCallMu.Unlock()
	if a.cloudCallCurrent == nil ||
		a.cloudCallCurrent.CallID != descriptor.CallID ||
		!strings.EqualFold(a.cloudCallCurrent.CallUUID, descriptor.CallUUID) ||
		a.cloudCallCurrent.Generation != descriptor.Generation {
		return
	}
	if a.cloudCallCancel != nil {
		a.cloudCallCancel()
	}
	a.cloudCallCancel = nil
	a.cloudCallCurrent = nil
}

func (a *agent) runCloudCall(ctx context.Context, descriptor cloudCallDescriptor) {
	descriptor.MediaTransport = resolveCloudMediaTransport(
		descriptor.MediaTransport,
		[]string{cloudMediaTransportLegacyPCM},
		false,
	)
	endpoint, err := cloudMediaURL(descriptor.RelayURL, descriptor.CallUUID, descriptor.CallSecret)
	if err != nil {
		a.debug.add("cloud-call", "error", "公网媒体地址无效", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
		return
	}
	health := newCloudMediaHealthTracker(time.Now(), descriptor)
	deadline := time.Now().Add(3 * time.Minute)
	for ctx.Err() == nil && time.Now().Before(deadline) && a.cloudCallDescriptorAlive(descriptor) {
		socket, err := dialCloudWebSocket(ctx, endpoint)
		if err != nil {
			a.debug.add("cloud-call", "error", "连接公网媒体失败", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
			if !health.beginRebuild(cloudMediaRebuildConnectionLost, time.Now()) {
				a.debug.add(
					"cloud-call", "failed", "公网媒体达到每通三次重建上限", err.Error(),
					cloudCallTraceFields(descriptor, cloudCallAction{}),
				)
				return
			}
			if !waitCloudRetry(ctx, 2*time.Second) {
				return
			}
			continue
		}
		a.debug.add("cloud-call", "connected", "公网媒体已连接", "", cloudCallTraceFields(descriptor, cloudCallAction{}))
		terminal := a.serveCloudCall(ctx, socket, descriptor, health)
		_ = socket.Close()
		if terminal {
			return
		}
		if !health.beginRebuild(cloudMediaRebuildConnectionLost, time.Now()) {
			a.debug.add(
				"cloud-call", "failed", "公网媒体达到每通三次重建上限", "",
				cloudCallTraceFields(descriptor, cloudCallAction{}),
			)
			return
		}
		if !waitCloudRetry(ctx, time.Second) {
			return
		}
	}
}

func (a *agent) cloudCallDescriptorAlive(descriptor cloudCallDescriptor) bool {
	if descriptor.Direction != "outgoing" {
		return a.cloudCallStillExists(descriptor.CallID)
	}
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.calls.Active != nil && a.calls.Active.Direction == "outgoing" {
		return true
	}
	// ATD 成功到首个 CLCC/DSCI 之间允许短暂没有本地通话记录。
	return !descriptor.StartedAt.IsZero() && time.Since(descriptor.StartedAt) < 20*time.Second
}

func waitCloudRetry(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func establishCloudPCMConnection(
	ctx context.Context,
	ensureListening func() error,
	dial func(context.Context) (net.Conn, error),
) (net.Conn, error) {
	if err := ensureListening(); err != nil {
		return nil, err
	}
	return dial(ctx)
}

func (a *agent) cloudCallStillExists(callID string) bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.calls.Active != nil && a.calls.Active.ID == callID
}

type cloudPCMBridge struct {
	mu               sync.Mutex
	conn             net.Conn
	health           *cloudMediaHealthTracker
	mediaProtocol    string
	downlinkSequence uint32
	uplinkBuffer     cloudPCMSpeechBuffer
	uplinkFramer     cloudPCMFramer
}

func (bridge *cloudPCMBridge) write(data []byte) error {
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.conn == nil {
		return errors.New("模块 PCM 尚未启动")
	}
	frame, _, decodeErr := decodeCloudPCMFrame(data)
	if decodeErr != nil {
		return decodeErr
	}
	previousDrops := bridge.uplinkBuffer.dropped
	for _, pcm := range bridge.uplinkFramer.append(frame.Payload) {
		bridge.uplinkBuffer.enqueue(pcm, time.Now())
	}
	bridge.health.addDroppedFrames(bridge.uplinkBuffer.dropped - previousDrops)
	bridge.health.observeUplinkBuffer(len(bridge.uplinkBuffer.frames), bridge.uplinkBuffer.target, bridge.uplinkBuffer.underruns)
	return nil
}

func (bridge *cloudPCMBridge) playUplink(ctx context.Context) {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			bridge.mu.Lock()
			if bridge.conn != nil {
				frame := bridge.uplinkBuffer.pop()
				if len(frame) > 0 {
					// Bounded local write: this worker never blocks WebSocket control reads.
					_ = bridge.conn.SetWriteDeadline(time.Now().Add(250 * time.Millisecond))
					remaining := frame
					for len(remaining) > 0 {
						n, err := bridge.conn.Write(remaining)
						remaining = remaining[n:]
						if err != nil || n == 0 {
							bridge.health.addDroppedFrames(1)
							_ = bridge.conn.Close()
							break
						}
					}
					if len(remaining) == 0 {
						bridge.health.observeUplink(frame, time.Now())
					}
				}
				bridge.health.observeUplinkBuffer(len(bridge.uplinkBuffer.frames), bridge.uplinkBuffer.target, bridge.uplinkBuffer.underruns)
			}
			bridge.mu.Unlock()
		}
	}
}

func (bridge *cloudPCMBridge) setMediaProtocol(value string) {
	bridge.mu.Lock()
	bridge.mediaProtocol = normalizedCloudPCMProtocol(value)
	protocol := bridge.mediaProtocol
	bridge.mu.Unlock()
	bridge.health.setMediaProtocol(protocol)
}

func (bridge *cloudPCMBridge) frameDownlink(payload []byte, timestamp time.Time) []byte {
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.mediaProtocol != cloudPCMProtocolFramedV1 {
		return payload
	}
	sequence := bridge.downlinkSequence
	bridge.downlinkSequence++
	return encodeCloudPCMFrame(payload, sequence, uint64(timestamp.UnixMilli()))
}

func (bridge *cloudPCMBridge) set(connection net.Conn) {
	bridge.mu.Lock()
	if bridge.conn != nil {
		_ = bridge.conn.Close()
	}
	bridge.conn = connection
	bridge.uplinkBuffer = cloudPCMSpeechBuffer{}
	bridge.uplinkFramer = cloudPCMFramer{}
	bridge.mu.Unlock()
}

func (bridge *cloudPCMBridge) close() {
	bridge.mu.Lock()
	if bridge.conn != nil {
		_ = bridge.conn.Close()
	}
	bridge.conn = nil
	bridge.mu.Unlock()
}

func (bridge *cloudPCMBridge) clear(connection net.Conn) {
	bridge.mu.Lock()
	if bridge.conn == connection {
		_ = bridge.conn.Close()
		bridge.conn = nil
	}
	bridge.mu.Unlock()
}

func (a *agent) serveCloudCall(
	ctx context.Context,
	socket *cloudWebSocket,
	descriptor cloudCallDescriptor,
	health *cloudMediaHealthTracker,
) bool {
	bridge := &cloudPCMBridge{health: health}
	defer bridge.close()
	playbackContext, stopPlayback := context.WithCancel(ctx)
	defer stopPlayback()
	go bridge.playUplink(playbackContext)
	mediaStarted := false
	_ = socket.WriteText(cloudStatusForAction("agent_ready", "", descriptor, cloudCallAction{}))

	watchEnded := make(chan struct{})
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		seenOutgoing := false
		missingSince := time.Now()
		for {
			select {
			case <-ctx.Done():
				_ = socket.Close()
				return
			case <-watchEnded:
				return
			case <-ticker.C:
				alive := false
				if descriptor.Direction == "outgoing" {
					a.mu.RLock()
					alive = a.calls.Active != nil && a.calls.Active.Direction == "outgoing"
					a.mu.RUnlock()
					seenOutgoing = seenOutgoing || alive
					if !seenOutgoing && time.Since(missingSince) < 20*time.Second {
						continue
					}
				} else {
					alive = a.cloudCallStillExists(descriptor.CallID)
				}
				if alive {
					continue
				}
				_ = socket.WriteText(cloudStatus("remote_ended", ""))
				_ = socket.Close()
				return
			}
		}
	}()
	defer close(watchEnded)

	for ctx.Err() == nil {
		opcode, payload, err := socket.ReadMessage()
		if err != nil {
			a.debug.add("cloud-call", "disconnected", "公网媒体连接中断", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
			return false
		}
		switch opcode {
		case cloudOpcodeBinary:
			if mediaStarted {
				_ = bridge.write(payload)
			}
		case cloudOpcodeText:
			control, err := decodeCloudCallActionForDescriptor(payload, descriptor)
			if err != nil {
				_ = socket.WriteText(cloudStatus("action_error", err.Error()))
				a.debug.add("cloud-call-control", "rejected", "公网通话控制校验失败", err.Error(), cloudCallTraceFields(descriptor, cloudCallAction{}))
				continue
			}
			fields := cloudCallTraceFields(descriptor, control)
			a.debug.add("cloud-call-control", "received", "收到公网通话控制", "", fields)
			switch control.Action {
			case "answer":
				startMedia := false
				if !mediaStarted {
					bridge.setMediaProtocol(control.MediaProtocol)
					mediaStarted = true
					startMedia = true
					if descriptor.Direction != "outgoing" {
						a.debug.add("cloud-call-control", "modem_executing", "执行接听命令", a.callControlBackendDescription(), fields)
						if err := a.executeIncomingCloudCallAction(control, "answer"); err != nil {
							mediaStarted = false
							_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
							a.debug.add("cloud-call-control", "failed", "公网接听执行失败", err.Error(), fields)
							continue
						}
						a.voice.mu.Lock()
						a.voice.hostEnabled = true
						a.voice.mu.Unlock()
					}
				}
				health.markAnswerAcknowledged(time.Now())
				_ = socket.WriteText(cloudStatusForAction(cloudPCMMilestoneAnswerOK, "", descriptor, control))
				a.debug.add("cloud-call-control", "completed", "公网接听命令已执行", "", fields)
				if startMedia {
					if descriptor.Direction == "outgoing" {
						go a.startOutgoingCloudPCM(ctx, socket, bridge, descriptor, health)
					} else {
						go a.connectCloudPCM(ctx, socket, bridge, descriptor, health)
					}
				}
				if descriptor.Direction != "outgoing" {
					go func() {
						if err := a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "active"); err != nil {
							a.debug.add("cloud-call", "error", "同步接听所有权失败", err.Error(), map[string]string{"call_id": descriptor.CallID, "owner": control.Owner})
						}
					}()
				}
			case "reject":
				a.debug.add("cloud-call-control", "modem_executing", "执行拒接命令", a.callControlBackendDescription(), fields)
				if err := a.executeIncomingCloudCallAction(control, "reject"); err != nil {
					_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
					a.debug.add("cloud-call-control", "failed", "公网拒接执行失败", err.Error(), fields)
					continue
				}
				_ = socket.WriteText(cloudStatusForAction("rejected", "", descriptor, control))
				a.debug.add("cloud-call-control", "completed", "公网拒接命令已执行", "", fields)
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
				return true
			case "end":
				if a.profile.AndroidTelecom {
					a.debug.add("cloud-call-control", "modem_executing", "执行挂断命令", a.callControlBackendDescription(), fields)
					if err := a.executeIncomingCloudCallAction(control, "end"); err != nil {
						_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
						a.debug.add("cloud-call-control", "failed", "公网挂断执行失败", err.Error(), fields)
						continue
					}
					_ = socket.WriteText(cloudStatusForAction("ended", "", descriptor, control))
					a.debug.add("cloud-call-control", "completed", "公网挂断已由 Android Telecom 接受", "", fields)
					go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
					return true
				}
				a.debug.add("cloud-call-control", "modem_executing", "执行挂断并确认基带状态", "ATH（失败时回退 AT+CHUP）→ AT+CLCC", fields)
				attempts, lastCLCC, err := a.hangupCallConfirmed()
				if err != nil {
					_ = socket.WriteText(cloudStatusForAction("action_error", err.Error(), descriptor, control))
					a.debug.add("cloud-call-control", "failed", "公网挂断执行失败", err.Error(), fields)
					continue
				}
				_ = socket.WriteText(cloudStatusForAction("ended", "", descriptor, control))
				fields["clcc_attempts"] = fmt.Sprintf("%d", attempts)
				a.debug.add("cloud-call-control", "completed", "公网挂断已由 CLCC 确认", lastCLCC, fields)
				go func() { _ = a.push.sendCallOwner(descriptor.CallID, descriptor.CallUUID, control.Owner, "ended") }()
				return true
			}
		}
	}
	return false
}

func (a *agent) callControlBackendDescription() string {
	if a.profile.AndroidTelecom {
		return "Android Telecom"
	}
	return "AT"
}

func (a *agent) executeIncomingCloudCallAction(control cloudCallAction, action string) error {
	if !a.profile.AndroidTelecom {
		switch action {
		case "answer":
			return a.answerCall()
		case "reject":
			return a.rejectCall()
		default:
			return fmt.Errorf("不支持的通话动作: %s", action)
		}
	}
	commandID := control.CommandID
	if commandID == "" {
		commandID = fmt.Sprintf("cloud-%d", time.Now().UnixNano())
	}
	result := a.executeAndroidCallCommand(commandID, action)
	if result.Success {
		return nil
	}
	if result.Error == "" {
		result.Error = "Android Telecom 未确认命令"
	}
	return errors.New(result.Error)
}

func cloudStatus(status, message string) []byte {
	value := map[string]string{"status": status}
	if message != "" {
		value["message"] = message
	}
	data, _ := json.Marshal(value)
	return data
}

const (
	cloudPCMMilestoneAnswerOK   = "answer_ok"
	cloudPCMMilestoneListening  = "pcm_listening"
	cloudPCMMilestoneActive     = "active"
	cloudPCMMilestoneReady      = "pcm_ready"
	cloudPCMMilestoneFirstFrame = "pcm_first_frame"
)

func validateCloudPCMMilestoneOrder(statuses []string) error {
	ranks := map[string]int{
		cloudPCMMilestoneAnswerOK: 1, cloudPCMMilestoneListening: 2,
		cloudPCMMilestoneActive: 3, cloudPCMMilestoneReady: 4,
		cloudPCMMilestoneFirstFrame: 5,
	}
	last := 0
	for _, status := range statuses {
		rank, ok := ranks[status]
		if !ok {
			return fmt.Errorf("unknown cloud PCM milestone %q", status)
		}
		if rank < last {
			return fmt.Errorf("cloud PCM milestone %q regressed after rank %d", status, last)
		}
		last = rank
	}
	return nil
}

type cloudPCMTransmissionStats struct {
	DownlinkBytes             uint64 `json:"downlink_bytes"`
	DownlinkFrames            uint64 `json:"downlink_frames"`
	DownlinkPeak              uint64 `json:"downlink_peak"`
	UplinkBytes               uint64 `json:"uplink_bytes"`
	UplinkFrames              uint64 `json:"uplink_frames"`
	UplinkPeak                uint64 `json:"uplink_peak"`
	DroppedFrames             uint64 `json:"dropped_frames"`
	JitterBufferHighWatermark int    `json:"jitter_buffer_high_watermark"`
	RebuildCount              int    `json:"rebuild_count"`
	AudioRoute                string `json:"audio_route"`
	MediaProtocol             string `json:"media_protocol,omitempty"`
	UplinkBufferTargetMS      int    `json:"uplink_buffer_target_ms"`
	UplinkBufferFrames        int    `json:"uplink_buffer_frames"`
	UplinkUnderruns           uint64 `json:"uplink_underruns"`
}

func cloudPCMStatus(status, message string, stats cloudPCMTransmissionStats) []byte {
	value := map[string]any{
		"status":                       status,
		"downlink_bytes":               stats.DownlinkBytes,
		"downlink_frames":              stats.DownlinkFrames,
		"downlink_peak":                stats.DownlinkPeak,
		"uplink_bytes":                 stats.UplinkBytes,
		"uplink_frames":                stats.UplinkFrames,
		"uplink_peak":                  stats.UplinkPeak,
		"dropped_frames":               stats.DroppedFrames,
		"jitter_buffer_high_watermark": stats.JitterBufferHighWatermark,
		"rebuild_count":                stats.RebuildCount,
		"audio_route":                  stats.AudioRoute,
		"media_protocol":               stats.MediaProtocol,
		"uplink_buffer_target_ms":      stats.UplinkBufferTargetMS,
		"uplink_buffer_frames":         stats.UplinkBufferFrames,
		"uplink_underruns":             stats.UplinkUnderruns,
	}
	if message != "" {
		value["message"] = message
	}
	data, _ := json.Marshal(value)
	return data
}

func cloudPCMTransmissionStatsFromHealth(snapshot cloudMediaHealthSnapshot) cloudPCMTransmissionStats {
	return cloudPCMTransmissionStats{
		DownlinkBytes: snapshot.DownlinkBytes, DownlinkFrames: snapshot.DownlinkFrames,
		DownlinkPeak: snapshot.DownlinkPeak, UplinkBytes: snapshot.UplinkBytes,
		UplinkFrames: snapshot.UplinkFrames, UplinkPeak: snapshot.UplinkPeak,
		DroppedFrames:             snapshot.DroppedFrames,
		JitterBufferHighWatermark: snapshot.JitterBufferHighWatermark,
		RebuildCount:              snapshot.RebuildCount, AudioRoute: snapshot.AudioRoute,
		MediaProtocol:        snapshot.MediaProtocol,
		UplinkBufferTargetMS: snapshot.UplinkBufferTargetMS,
		UplinkBufferFrames:   snapshot.UplinkBufferFrames,
		UplinkUnderruns:      snapshot.UplinkUnderruns,
	}
}

func cloudPCMMilestoneFields(snapshot cloudMediaHealthSnapshot) map[string]string {
	fields := map[string]string{}
	if !snapshot.AnswerAcknowledgedAt.IsZero() && !snapshot.ListeningAt.IsZero() {
		fields["answer_to_listen_ms"] = fmt.Sprintf("%d", snapshot.ListeningAt.Sub(snapshot.AnswerAcknowledgedAt).Milliseconds())
	}
	if !snapshot.ListeningAt.IsZero() && !snapshot.HandshakeAt.IsZero() {
		fields["listen_to_handshake_ms"] = fmt.Sprintf("%d", snapshot.HandshakeAt.Sub(snapshot.ListeningAt).Milliseconds())
	}
	if !snapshot.HandshakeAt.IsZero() && !snapshot.FirstDownlinkAt.IsZero() {
		fields["handshake_to_first_downlink_ms"] = fmt.Sprintf("%d", snapshot.FirstDownlinkAt.Sub(snapshot.HandshakeAt).Milliseconds())
	}
	return fields
}

func cloudPCM16LEPeak(data []byte) uint64 {
	var peak uint64
	for offset := 0; offset+1 < len(data); offset += 2 {
		bits := uint16(data[offset]) | uint16(data[offset+1])<<8
		sample := int64(int16(bits))
		if sample < 0 {
			sample = -sample
		}
		if uint64(sample) > peak {
			peak = uint64(sample)
		}
	}
	return peak
}

func shouldRecoverCloudPCM(readError error, _ uint64) bool {
	var networkError net.Error
	return errors.As(readError, &networkError) && networkError.Timeout()
}

type cloudPCMRecoveryAction string

const (
	cloudPCMKeepVoiceRoute    cloudPCMRecoveryAction = "keep_voice_route"
	cloudPCMReconnectOnly     cloudPCMRecoveryAction = "reconnect_only"
	cloudPCMRebuildVoiceRoute cloudPCMRecoveryAction = "rebuild_voice_route"
)

func cloudPCMRecoveryForTimeout(consecutiveTimeouts int) cloudPCMRecoveryAction {
	if consecutiveTimeouts <= 1 {
		return cloudPCMReconnectOnly
	}
	return cloudPCMRebuildVoiceRoute
}

func cloudPCMRecoveryForHealth(decision cloudMediaHealthDecision) cloudPCMRecoveryAction {
	if decision == cloudMediaRebuildUplinkStalled {
		return cloudPCMKeepVoiceRoute
	}
	return cloudPCMRebuildVoiceRoute
}

func cloudPCMRecoveryTouchesUSB(action cloudPCMRecoveryAction) bool {
	switch action {
	case cloudPCMKeepVoiceRoute, cloudPCMReconnectOnly, cloudPCMRebuildVoiceRoute:
		return false
	default:
		// Unknown future recovery actions must fail the USB-safety invariant.
		return true
	}
}

func (a *agent) connectCloudPCM(
	ctx context.Context,
	socket *cloudWebSocket,
	bridge *cloudPCMBridge,
	descriptor cloudCallDescriptor,
	health *cloudMediaHealthTracker,
) {
	pcmEndpoint, endpointErr := a.voicePCMEndpoint()
	if endpointErr != nil {
		_ = socket.WriteText(cloudStatus("action_error", "PCM 后端配置无效"))
		a.debug.add("cloud-call", "failed", "PCM 后端配置无效", endpointErr.Error(),
			cloudCallTraceFields(descriptor, cloudCallAction{}))
		return
	}
	initialDeadline := time.Now().Add(45 * time.Second)
	everConnected := false
	consecutiveDialFailures := 0
	consecutiveReadTimeouts := 0
	for ctx.Err() == nil && a.cloudCallDescriptorAlive(descriptor) {
		if !everConnected && time.Now().After(initialDeadline) {
			_ = socket.WriteText(cloudStatus("action_error", "模块 PCM 启动超时"))
			return
		}
		// 只等待 7580 开始监听，随后立即建立客户端连接。完整 ready 状态必须
		// 在 AIRSIMPCM1/AIRSIMREADY 握手和双向线程启动后才成立。
		connection, err := establishCloudPCMConnection(
			ctx,
			a.ensureVoiceRouteListening,
			func(ctx context.Context) (net.Conn, error) {
				dialer := net.Dialer{Timeout: 2 * time.Second}
				return dialer.DialContext(ctx, "tcp", pcmEndpoint)
			},
		)
		if err != nil {
			consecutiveDialFailures++
			a.debug.add("voice-backend", "connect_failed", "连接三星 PCM 后端失败", err.Error(), map[string]string{
				"backend": string(a.voiceBackend.kind),
				"attempt": fmt.Sprintf("%d", consecutiveDialFailures),
			})
			// helper 曾经 ready 但监听端口已经消失时，旧实现会一直拨一个
			// 不存在的 7580。连续失败后只重建 D4/D5/D6，不重置 USB/ECM。
			if consecutiveDialFailures >= 3 {
				if !health.beginRebuild(cloudMediaRebuildConnectionLost, time.Now()) {
					_ = socket.WriteText(cloudPCMStatus(
						"action_error", "PCM 已达到每通三次重建上限",
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					return
				}
				a.voice.mu.Lock()
				staleReady := a.voice.ready
				a.voice.mu.Unlock()
				if staleReady {
					_ = socket.WriteText(cloudPCMStatus(
						"pcm_recovering", "PCM 监听失效，正在重建语音路由",
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					a.stopVoiceRoute()
				}
				consecutiveDialFailures = 0
			}
			if !waitCloudRetry(ctx, time.Second) {
				return
			}
			continue
		}
		health.markListening(time.Now())
		_ = socket.WriteText(cloudPCMStatus(
			cloudPCMMilestoneListening, "",
			cloudPCMTransmissionStatsFromHealth(health.snapshot()),
		))
		if err := cloudPCMHandshake(connection); err != nil {
			a.debug.add("voice-backend", "handshake_failed", "三星 PCM 握手失败", err.Error(), map[string]string{
				"backend": string(a.voiceBackend.kind),
			})
			_ = connection.Close()
			if !waitCloudRetry(ctx, time.Second) {
				return
			}
			continue
		}
		a.markVoiceBackendHandshakeReady()
		a.debug.add("voice-backend", "ready", "三星 PCM 媒体会话已建立", "", map[string]string{
			"backend": string(a.voiceBackend.kind),
		})
		consecutiveDialFailures = 0
		everConnected = true
		bridge.set(connection)
		health.beginMedia(time.Now())
		_ = socket.WriteText(cloudStatus(cloudPCMMilestoneActive, ""))
		_ = socket.WriteText(cloudPCMStatus(cloudPCMMilestoneReady, "", cloudPCMTransmissionStatsFromHealth(health.snapshot())))
		buffer := make([]byte, 4096)
		framer := cloudPCMFramer{}
		lastStatsAt := time.Time{}
		firstDownlinkReported := false
		_ = connection.SetReadDeadline(time.Now().Add(cloudMediaStartupInterval))
		for {
			count, readErr := connection.Read(buffer)
			if count > 0 {
				consecutiveReadTimeouts = 0
				_ = connection.SetReadDeadline(time.Now().Add(cloudMediaStallInterval))
				for _, frame := range framer.append(buffer[:count]) {
					outbound := bridge.frameDownlink(frame, time.Now())
					if err := socket.WriteBinary(outbound); err != nil {
						bridge.clear(connection)
						return
					}
					health.observeDownlink(frame, time.Now(), maxInt(0, framer.buffered()/cloudPCMFrameBytes))
					if !firstDownlinkReported {
						firstDownlinkReported = true
						snapshot := health.snapshot()
						_ = socket.WriteText(cloudPCMStatus(
							cloudPCMMilestoneFirstFrame, "",
							cloudPCMTransmissionStatsFromHealth(snapshot),
						))
						fields := cloudCallTraceFields(descriptor, cloudCallAction{})
						for key, value := range cloudPCMMilestoneFields(snapshot) {
							fields[key] = value
						}
						a.debug.add("cloud-call", cloudPCMMilestoneFirstFrame, "公网通话首个下行 PCM 已转发", "", fields)
					}
				}
				decision := health.evaluate(time.Now())
				if decision != cloudMediaHealthy && cloudPCMRecoveryForHealth(decision) != cloudPCMKeepVoiceRoute {
					bridge.clear(connection)
					if !health.beginRebuild(decision, time.Now()) {
						_ = socket.WriteText(cloudPCMStatus(
							"action_error", "PCM 已达到每通三次重建上限",
							cloudPCMTransmissionStatsFromHealth(health.snapshot()),
						))
						return
					}
					_ = socket.WriteText(cloudPCMStatus(
						"pcm_recovering", string(decision),
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					a.stopVoiceRoute()
					if !waitCloudRetry(ctx, 500*time.Millisecond) {
						return
					}
					break
				}
				if lastStatsAt.IsZero() || time.Since(lastStatsAt) >= time.Second {
					_ = socket.WriteText(cloudPCMStatus(
						"pcm_stats", "", cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					lastStatsAt = time.Now()
				}
			}
			if readErr != nil {
				decision := cloudMediaRebuildConnectionLost
				message := "PCM 连接中断，正在重新连接"
				if shouldRecoverCloudPCM(readErr, health.snapshot().DownlinkBytes) {
					decision = cloudMediaRebuildDownlinkStalled
					consecutiveReadTimeouts++
					if cloudPCMRecoveryForTimeout(consecutiveReadTimeouts) == cloudPCMReconnectOnly {
						_ = socket.WriteText(cloudPCMStatus(
							"pcm_waiting", "下行 PCM 短暂停顿，保留当前语音路由等待恢复",
							cloudPCMTransmissionStatsFromHealth(health.snapshot()),
						))
						_ = connection.SetReadDeadline(time.Now().Add(time.Second))
						continue
					}
					message = "下行 PCM 连续超时，正在重建语音路由"
				}
				bridge.clear(connection)
				if !health.beginRebuild(decision, time.Now()) {
					_ = socket.WriteText(cloudPCMStatus(
						"action_error", "PCM 已达到每通三次重建上限",
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					return
				}
				if decision == cloudMediaRebuildDownlinkStalled {
					_ = socket.WriteText(cloudPCMStatus(
						"pcm_recovering", message,
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
					a.stopVoiceRoute()
				} else {
					_ = socket.WriteText(cloudPCMStatus(
						"pcm_recovering", message,
						cloudPCMTransmissionStatsFromHealth(health.snapshot()),
					))
				}
				if !waitCloudRetry(ctx, 500*time.Millisecond) {
					return
				}
				break
			}
		}
	}
}

func (a *agent) startOutgoingCloudPCM(
	ctx context.Context,
	socket *cloudWebSocket,
	bridge *cloudPCMBridge,
	descriptor cloudCallDescriptor,
	health *cloudMediaHealthTracker,
) {
	deadline := time.Now().Add(3 * time.Minute)
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for ctx.Err() == nil && time.Now().Before(deadline) {
		a.mu.RLock()
		active := a.calls.Active != nil && a.calls.Active.Direction == "outgoing" &&
			(a.calls.Active.State == "active" || a.calls.Active.State == "held")
		a.mu.RUnlock()
		if active {
			a.voice.mu.Lock()
			a.voice.hostEnabled = true
			a.voice.mu.Unlock()
			a.connectCloudPCM(ctx, socket, bridge, descriptor, health)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

const (
	cloudPCMFrameBytes       = 320 // 20 ms, 8 kHz, mono PCM16LE
	cloudPCMProtocolFramedV1 = "airsim-pcm-v1"
	cloudPCMFrameHeaderBytes = 20
	cloudPCMFrameVersion     = byte(1)
)

var cloudPCMFrameMagic = [4]byte{'A', 'S', 'P', 'M'}

type cloudPCMFrame struct {
	Sequence              uint32
	TimestampMilliseconds uint64
	Payload               []byte
}

func normalizedCloudPCMProtocol(value string) string {
	if strings.EqualFold(strings.TrimSpace(value), cloudPCMProtocolFramedV1) {
		return cloudPCMProtocolFramedV1
	}
	return ""
}

func encodeCloudPCMFrame(payload []byte, sequence uint32, timestampMilliseconds uint64) []byte {
	wire := make([]byte, cloudPCMFrameHeaderBytes+len(payload))
	copy(wire[:4], cloudPCMFrameMagic[:])
	wire[4] = cloudPCMFrameVersion
	wire[5] = 0
	binary.BigEndian.PutUint16(wire[6:8], cloudPCMFrameHeaderBytes)
	binary.BigEndian.PutUint32(wire[8:12], sequence)
	binary.BigEndian.PutUint64(wire[12:20], timestampMilliseconds)
	copy(wire[cloudPCMFrameHeaderBytes:], payload)
	return wire
}

func decodeCloudPCMFrame(wire []byte) (cloudPCMFrame, bool, error) {
	if len(wire) < len(cloudPCMFrameMagic) || !bytes.Equal(wire[:4], cloudPCMFrameMagic[:]) {
		return cloudPCMFrame{Payload: wire}, false, nil
	}
	if len(wire) < cloudPCMFrameHeaderBytes {
		return cloudPCMFrame{}, true, errors.New("AirSIM PCM 帧头不完整")
	}
	headerBytes := int(binary.BigEndian.Uint16(wire[6:8]))
	if wire[4] != cloudPCMFrameVersion || headerBytes != cloudPCMFrameHeaderBytes {
		return cloudPCMFrame{}, true, errors.New("AirSIM PCM 帧版本无效")
	}
	payload := wire[headerBytes:]
	if len(payload) != cloudPCMFrameBytes {
		return cloudPCMFrame{}, true, fmt.Errorf("AirSIM PCM 负载长度=%d，期望 %d", len(payload), cloudPCMFrameBytes)
	}
	return cloudPCMFrame{
		Sequence:              binary.BigEndian.Uint32(wire[8:12]),
		TimestampMilliseconds: binary.BigEndian.Uint64(wire[12:20]),
		Payload:               payload,
	}, true, nil
}

// TCP 不保留应用层帧边界；缓存跨 read 的尾部，避免奇数字节读取截断一个 PCM16 样本。
type cloudPCMFramer struct {
	pending []byte
}

func (framer *cloudPCMFramer) append(chunk []byte) [][]byte {
	framer.pending = append(framer.pending, chunk...)
	frames := make([][]byte, 0, len(framer.pending)/cloudPCMFrameBytes)
	for len(framer.pending) >= cloudPCMFrameBytes {
		frame := make([]byte, cloudPCMFrameBytes)
		copy(frame, framer.pending[:cloudPCMFrameBytes])
		frames = append(frames, frame)
		framer.pending = framer.pending[cloudPCMFrameBytes:]
	}
	if len(framer.pending) == 0 {
		framer.pending = nil
	} else {
		framer.pending = append([]byte(nil), framer.pending...)
	}
	return frames
}

func (framer *cloudPCMFramer) buffered() int { return len(framer.pending) }

func cloudPCMHandshake(connection net.Conn) error {
	_ = connection.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := connection.Write([]byte("AIRSIMPCM1\n")); err != nil {
		return err
	}
	acknowledgement := make([]byte, len("AIRSIMREADY"))
	if _, err := io.ReadFull(connection, acknowledgement); err != nil {
		return err
	}
	if string(acknowledgement) != "AIRSIMREADY" {
		return errors.New("模块 PCM 握手无效")
	}
	return connection.SetDeadline(time.Time{})
}

const (
	cloudOpcodeText   = byte(1)
	cloudOpcodeBinary = byte(2)
	cloudOpcodeClose  = byte(8)
	cloudOpcodePing   = byte(9)
	cloudOpcodePong   = byte(10)
)

type cloudWebSocket struct {
	conn      net.Conn
	reader    *bufio.Reader
	writeMu   sync.Mutex
	closeOnce sync.Once
}

func dialCloudWebSocket(ctx context.Context, endpoint string) (*cloudWebSocket, error) {
	return dialCloudWebSocketAuthorized(ctx, endpoint, "")
}

func dialCloudWebSocketAuthorized(ctx context.Context, endpoint, bearerToken string) (*cloudWebSocket, error) {
	target, err := url.Parse(endpoint)
	if err != nil || target.Scheme != "wss" || target.Host == "" {
		return nil, errors.New("WSS 地址无效")
	}
	host := target.Host
	if !strings.Contains(host, ":") {
		host += ":443"
	}
	dialer := &net.Dialer{Timeout: 8 * time.Second, KeepAlive: 30 * time.Second}
	configurePushDialer(dialer)
	rawConnection, err := dialPushAddress(ctx, dialer, "tcp", host)
	if err != nil {
		return nil, err
	}
	connection := tls.Client(rawConnection, &tls.Config{
		ServerName: target.Hostname(), MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"},
	})
	handshakeContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if err := connection.HandshakeContext(handshakeContext); err != nil {
		_ = rawConnection.Close()
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	} else {
		_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
	}

	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		_ = connection.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	path := target.EscapedPath()
	if path == "" {
		path = "/"
	}
	if target.RawQuery != "" {
		path += "?" + target.RawQuery
	}
	authorization := ""
	if bearerToken != "" {
		authorization = "Authorization: Bearer " + bearerToken + "\r\n"
	}
	request := fmt.Sprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%sUser-Agent: AirSIM-QDC507/%s\r\n\r\n",
		path, target.Host, key, authorization, agentVersion,
	)
	if _, err := io.WriteString(connection, request); err != nil {
		_ = connection.Close()
		return nil, err
	}
	reader := bufio.NewReader(connection)
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		_ = connection.Close()
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusSwitchingProtocols ||
		!strings.EqualFold(response.Header.Get("Upgrade"), "websocket") ||
		response.Header.Get("Sec-WebSocket-Accept") != cloudWebSocketAccept(key) {
		_ = connection.Close()
		return nil, fmt.Errorf("公网媒体握手返回 HTTP %d", response.StatusCode)
	}
	_ = connection.SetDeadline(time.Time{})
	return &cloudWebSocket{conn: connection, reader: reader}, nil
}

func cloudWebSocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func (socket *cloudWebSocket) WriteText(data []byte) error {
	return socket.writeMessage(cloudOpcodeText, data)
}
func (socket *cloudWebSocket) WriteBinary(data []byte) error {
	return socket.writeMessage(cloudOpcodeBinary, data)
}

func (socket *cloudWebSocket) writeMessage(opcode byte, payload []byte) error {
	if len(payload) > 65_535 {
		return errors.New("WebSocket 帧过大")
	}
	socket.writeMu.Lock()
	defer socket.writeMu.Unlock()
	header := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		header = append(header, 0x80|byte(len(payload)))
	default:
		header = append(header, 0x80|126, byte(len(payload)>>8), byte(len(payload)))
	}
	mask := make([]byte, 4)
	if _, err := rand.Read(mask); err != nil {
		return err
	}
	header = append(header, mask...)
	encoded := make([]byte, len(payload))
	for index := range payload {
		encoded[index] = payload[index] ^ mask[index%4]
	}
	if _, err := socket.conn.Write(header); err != nil {
		return err
	}
	_, err := socket.conn.Write(encoded)
	return err
}

func (socket *cloudWebSocket) ReadMessage() (byte, []byte, error) {
	for {
		first, err := socket.reader.ReadByte()
		if err != nil {
			return 0, nil, err
		}
		second, err := socket.reader.ReadByte()
		if err != nil {
			return 0, nil, err
		}
		opcode := first & 0x0f
		length := uint64(second & 0x7f)
		if length == 126 {
			var value uint16
			if err := binary.Read(socket.reader, binary.BigEndian, &value); err != nil {
				return 0, nil, err
			}
			length = uint64(value)
		} else if length == 127 {
			if err := binary.Read(socket.reader, binary.BigEndian, &length); err != nil {
				return 0, nil, err
			}
		}
		if length > 65_535 {
			return 0, nil, errors.New("公网 WebSocket 帧过大")
		}
		var mask [4]byte
		masked := second&0x80 != 0
		if masked {
			if _, err := io.ReadFull(socket.reader, mask[:]); err != nil {
				return 0, nil, err
			}
		}
		payload := make([]byte, int(length))
		if _, err := io.ReadFull(socket.reader, payload); err != nil {
			return 0, nil, err
		}
		if masked {
			for index := range payload {
				payload[index] ^= mask[index%4]
			}
		}
		switch opcode {
		case cloudOpcodePing:
			if err := socket.writeMessage(cloudOpcodePong, payload); err != nil {
				return 0, nil, err
			}
			continue
		case cloudOpcodePong:
			continue
		case cloudOpcodeClose:
			return 0, nil, io.EOF
		case cloudOpcodeText, cloudOpcodeBinary:
			return opcode, payload, nil
		default:
			return 0, nil, errors.New("不支持的 WebSocket 帧")
		}
	}
}

func (socket *cloudWebSocket) Close() error {
	var err error
	socket.closeOnce.Do(func() {
		_ = socket.writeMessage(cloudOpcodeClose, nil)
		err = socket.conn.Close()
	})
	return err
}
