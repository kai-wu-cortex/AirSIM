package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type callRecord struct {
	ID        string     `json:"id"`
	Index     int        `json:"index"`
	Direction string     `json:"direction"`
	State     string     `json:"state"`
	Number    string     `json:"number,omitempty"`
	StartedAt time.Time  `json:"started_at"`
	UpdatedAt time.Time  `json:"updated_at"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
	Missed    bool       `json:"missed"`
	AndroidID string     `json:"-"`
}

type callTracker struct {
	Active        *callRecord
	History       []callRecord
	LastPollError string
	Configured    bool
	EventDriven   bool
	LastAnswerAt  time.Time
	RecentlyEnded *endedCallTombstone
}

func (a *agent) applyAndroidCallEvent(event androidCallEvent, now time.Time) {
	a.mu.Lock()
	active := a.calls.Active
	if event.State == "ended" {
		if active == nil || active.AndroidID != event.CallID {
			a.mu.Unlock()
			return
		}
		endedID, previousState := active.ID, active.State
		ended := now
		active.EndedAt, active.UpdatedAt = &ended, now
		active.Missed = active.Direction == "incoming" && (active.State == "incoming" || active.State == "waiting")
		a.calls.History = append([]callRecord{*active}, a.calls.History...)
		a.calls.Active = nil
		a.muted, a.isRecording = false, false
		a.notifyCallChangedLocked()
		a.mu.Unlock()
		if a.push != nil {
			go func() { _ = a.push.sendCallState(endedID, "ended") }()
		}
		appendVoiceDiagnosticEvent("Android 通话状态变更: " + previousState + " -> ended")
		go func() {
			time.Sleep(1500 * time.Millisecond)
			a.mu.RLock()
			stillIdle := a.calls.Active == nil
			a.mu.RUnlock()
			if stillIdle {
				a.stopVoiceRoute()
			}
		}()
		return
	}
	if active == nil || active.AndroidID != event.CallID {
		if active != nil {
			ended := now
			active.EndedAt, active.UpdatedAt = &ended, now
			a.calls.History = append([]callRecord{*active}, a.calls.History...)
		}
		a.calls.Active = &callRecord{
			ID: fmt.Sprintf("android-%d", now.UnixMilli()), AndroidID: event.CallID,
			Index: 1, Direction: event.Direction, State: event.State,
			Number: event.Number, StartedAt: now, UpdatedAt: now,
		}
		callID := a.calls.Active.ID
		shouldPush := event.Direction == "incoming" && event.State == "incoming"
		a.notifyCallChangedLocked()
		a.mu.Unlock()
		if shouldPush {
			a.scheduleIncomingPush(callID)
		}
		if a.push != nil {
			if phase := lifecyclePhaseForModemState(event.State); phase != "" {
				go func() { _ = a.push.sendCallState(callID, phase) }()
			}
		}
		if event.State == "active" {
			go a.ensureVoiceRouteIfHostEnabled()
		}
		return
	}
	previousState := active.State
	changed := previousState != event.State || (event.Number != "" && active.Number != event.Number)
	active.State = event.State
	if event.Number != "" {
		active.Number = event.Number
	}
	if changed {
		active.UpdatedAt = now
		a.notifyCallChangedLocked()
	}
	callID := active.ID
	a.mu.Unlock()
	if changed && a.push != nil {
		if phase := lifecyclePhaseForModemState(event.State); phase != "" {
			go func() { _ = a.push.sendCallState(callID, phase) }()
		}
	}
	if event.State == "active" && previousState != "active" {
		go a.ensureVoiceRouteIfHostEnabled()
	}
}

type endedCallTombstone struct {
	Index     int
	Direction string
	Number    string
	EndedAt   time.Time
}

const endedCallTombstoneRetention = 3 * time.Second

type parsedCall struct {
	Index     int
	Direction string
	State     string
	Number    string
}

var clccPattern = regexp.MustCompile(`\+CLCC:\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*"([^"]*)")?`)

func parseDSCI(line string) (parsedCall, bool, bool) {
	fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "^DSCI:")))
	if len(fields) < 4 || fields[3] != "0" {
		return parsedCall{}, false, false
	}
	index, indexErr := strconv.Atoi(fields[0])
	stateCode, stateErr := strconv.Atoi(fields[2])
	if indexErr != nil || stateErr != nil {
		return parsedCall{}, false, false
	}
	if stateCode == 6 {
		return parsedCall{Index: index}, true, true
	}
	states := map[int]string{1: "held", 2: "dialing", 3: "active", 4: "incoming", 5: "waiting", 7: "alerting"}
	state, ok := states[stateCode]
	if !ok {
		return parsedCall{}, false, false
	}
	direction := "outgoing"
	if fields[1] == "1" {
		direction = "incoming"
	}
	number := ""
	if len(fields) > 4 {
		number = strings.Trim(fields[4], `"`)
	}
	return parsedCall{Index: index, Direction: direction, State: state, Number: number}, false, true
}

func (a *agent) requestCallRefresh() {
	select {
	case a.callRefresh <- struct{}{}:
	default:
	}
}

func (a *agent) handleURC(line string) {
	upper := strings.ToUpper(strings.TrimSpace(line))
	if strings.HasPrefix(upper, "+CEREG:") || strings.HasPrefix(upper, "+CREG:") {
		a.observeCellularRegistration(parseRegistration(line), "urc")
		return
	}
	if call, ended, ok := parseDSCI(line); ok {
		if ended {
			a.applyCallPoll(nil, time.Now())
		} else {
			a.applyCallPoll([]parsedCall{call}, time.Now())
		}
		return
	}
	if strings.HasPrefix(upper, "+CLIP:") {
		fields := splitCSV(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "+CLIP:")))
		if len(fields) > 0 {
			a.mu.Lock()
			if number := strings.Trim(fields[0], `"`); a.calls.Active != nil && number != "" && a.calls.Active.Number != number {
				a.calls.Active.Number = number
				a.calls.Active.UpdatedAt = time.Now()
				a.notifyCallChangedLocked()
			}
			a.mu.Unlock()
		}
		a.requestCallRefresh()
		return
	}
	if upper == "RING" || strings.HasPrefix(upper, "+CRING:") {
		a.requestCallRefresh()
		return
	}
	if notice, ok := parseSMSStorageURC(line); ok {
		a.enqueueSMSNotice(notice)
	}
}

func parseCLCC(response string) []parsedCall {
	matches := clccPattern.FindAllStringSubmatch(response, -1)
	calls := make([]parsedCall, 0, len(matches))
	for _, match := range matches {
		// CLCC mode 0 才是语音，数据会话不能伪装成电话。
		if match[4] != "0" {
			continue
		}
		index, err := strconv.Atoi(match[1])
		if err != nil {
			continue
		}
		direction := "outgoing"
		if match[2] == "1" {
			direction = "incoming"
		}
		calls = append(calls, parsedCall{Index: index, Direction: direction, State: mapCallState(match[3]), Number: strings.TrimSpace(match[6])})
	}
	return calls
}

func mapCallState(raw string) string {
	switch raw {
	case "0":
		return "active"
	case "1":
		return "held"
	case "2":
		return "dialing"
	case "3":
		return "alerting"
	case "4":
		return "incoming"
	case "5":
		return "waiting"
	default:
		return "unknown"
	}
}

func callStatePriority(state string) int {
	switch state {
	case "incoming", "waiting":
		return 5
	case "active":
		return 4
	case "alerting":
		return 3
	case "dialing":
		return 2
	case "held":
		return 1
	default:
		return 0
	}
}

func (a *agent) refreshCalls() {
	a.mu.Lock()
	configured := a.calls.Configured
	a.mu.Unlock()
	if !configured {
		if _, err := a.at.command("AT+CLIP=1", 3*time.Second); err != nil {
			a.setCallError(err)
			return
		}
		eventDriven := false
		_, _ = a.at.command("AT+CRC=1", 3*time.Second)
		if _, err := a.at.command("AT^DSCI=1", 3*time.Second); err == nil {
			eventDriven = true
		}
		a.mu.Lock()
		a.calls.Configured = true
		a.calls.EventDriven = eventDriven
		a.mu.Unlock()
	}

	response, err := a.at.command("AT+CLCC", 3*time.Second)
	if err != nil {
		a.setCallError(err)
		return
	}
	a.applyCallPoll(parseCLCC(response), time.Now())
	a.setCallError(nil)
}

func (a *agent) setCallError(err error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	previous := a.calls.LastPollError
	if err == nil {
		a.calls.LastPollError = ""
	} else {
		a.calls.LastPollError = err.Error()
	}
	if a.calls.LastPollError != previous {
		a.notifyCallChangedLocked()
	}
}

// notifyCallChangedLocked broadcasts one meaningful call-state revision to every
// waiting client. The caller must hold a.mu for writing.
func (a *agent) notifyCallChangedLocked() {
	a.callRevision++
	if a.callChanged != nil {
		close(a.callChanged)
	}
	a.callChanged = make(chan struct{})
	a.notifyAgentEventChangedLocked()
}

func (a *agent) notifyAgentEventChangedLocked() {
	a.eventRevision++
	if a.eventChanged != nil {
		close(a.eventChanged)
	}
	a.eventChanged = make(chan struct{})
}

func (a *agent) applyCallPoll(calls []parsedCall, now time.Time) {
	var selected *parsedCall
	for index := range calls {
		candidate := &calls[index]
		if selected == nil || callStatePriority(candidate.State) > callStatePriority(selected.State) {
			selected = candidate
		}
	}

	a.mu.Lock()
	if selected != nil && a.calls.RecentlyEnded != nil {
		tombstone := a.calls.RecentlyEnded
		age := now.Sub(tombstone.EndedAt)
		sameNumber := tombstone.Number == "" || selected.Number == "" || tombstone.Number == selected.Number
		if age >= 0 && age <= endedCallTombstoneRetention &&
			tombstone.Index == selected.Index && tombstone.Direction == selected.Direction && sameNumber {
			a.mu.Unlock()
			appendVoiceDiagnosticEvent("忽略挂断后陈旧 CLCC: " + selected.State)
			return
		}
		if age > endedCallTombstoneRetention || tombstone.Index != selected.Index ||
			tombstone.Direction != selected.Direction || !sameNumber {
			a.calls.RecentlyEnded = nil
		}
	}
	if selected == nil {
		if a.calls.Active == nil {
			a.mu.Unlock()
			return
		}
		ended := now
		endedCallID := a.calls.Active.ID
		endedState := a.calls.Active.State
		a.calls.RecentlyEnded = &endedCallTombstone{
			Index: a.calls.Active.Index, Direction: a.calls.Active.Direction,
			Number: a.calls.Active.Number, EndedAt: ended,
		}
		a.calls.Active.EndedAt = &ended
		a.calls.Active.UpdatedAt = now
		a.calls.Active.Missed = a.calls.Active.Direction == "incoming" &&
			(a.calls.Active.State == "incoming" || a.calls.Active.State == "waiting")
		a.calls.History = append([]callRecord{*a.calls.Active}, a.calls.History...)
		a.calls.Active = nil
		a.muted = false
		a.isRecording = false
		a.notifyCallChangedLocked()
		a.mu.Unlock()
		if a.push != nil {
			go func() { _ = a.push.sendCallState(endedCallID, "ended") }()
		}
		appendVoiceDiagnosticEvent("通话状态变更: " + endedState + " -> ended")
		// 等基带彻底结束通话后再回滚 UAC 路由，避免尾音被硬切断。
		go func() {
			time.Sleep(1500 * time.Millisecond)
			a.mu.RLock()
			stillIdle := a.calls.Active == nil
			a.mu.RUnlock()
			if stillIdle {
				a.stopVoiceRoute()
			}
		}()
		return
	}

	if a.calls.Active == nil || a.calls.Active.Index != selected.Index || a.calls.Active.Direction != selected.Direction {
		a.calls.Active = &callRecord{
			ID: fmt.Sprintf("%d-%d", now.UnixMilli(), selected.Index), Index: selected.Index,
			Direction: selected.Direction, State: selected.State, Number: selected.Number,
			StartedAt: now, UpdatedAt: now,
		}
		callID := a.calls.Active.ID
		shouldPush := a.calls.Active.Direction == "incoming" &&
			(a.calls.Active.State == "incoming" || a.calls.Active.State == "waiting")
		a.notifyCallChangedLocked()
		a.mu.Unlock()
		if shouldPush {
			a.scheduleIncomingPush(callID)
		}
		if a.push != nil {
			if phase := lifecyclePhaseForModemState(selected.State); phase != "" {
				go func() { _ = a.push.sendCallState(callID, phase) }()
			}
		}
		appendVoiceDiagnosticEvent("通话状态变更: idle -> " + selected.State)
		if selected.State == "active" {
			go a.ensureVoiceRouteIfHostEnabled()
		} else {
			// 在响铃或拨号阶段提前完成驱动加载和 ACDB 校准；接通后只需建立
			// D4/D5/D6 路由，避免把模块冷启动时间暴露给用户。
			go a.ensureVoiceRuntimeWarm()
		}
		return
	}
	previousState := a.calls.Active.State
	stateChanged := previousState != selected.State
	numberChanged := selected.Number != "" && a.calls.Active.Number != selected.Number
	if stateChanged {
		a.calls.Active.State = selected.State
	}
	if numberChanged {
		a.calls.Active.Number = selected.Number
	}
	if stateChanged || numberChanged {
		a.calls.Active.UpdatedAt = now
		a.notifyCallChangedLocked()
	}
	callID := a.calls.Active.ID
	shouldPush := stateChanged && a.calls.Active.Direction == "incoming" &&
		(a.calls.Active.State == "incoming" || a.calls.Active.State == "waiting")
	a.mu.Unlock()
	if shouldPush {
		a.scheduleIncomingPush(callID)
	}
	if selected.State != previousState {
		appendVoiceDiagnosticEvent("通话状态变更: " + previousState + " -> " + selected.State)
		if a.push != nil {
			if phase := lifecyclePhaseForModemState(selected.State); phase != "" {
				go func() { _ = a.push.sendCallState(callID, phase) }()
			}
		}
	}
	if selected.State == "active" && previousState != "active" {
		go a.ensureVoiceRouteIfHostEnabled()
	}
}

func lifecyclePhaseForModemState(state string) string {
	switch state {
	case "incoming", "waiting":
		return "ringing"
	case "dialing", "alerting":
		return "connecting"
	case "active", "held":
		return "active"
	default:
		return ""
	}
}

func (a *agent) callStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	writeJSON(response, http.StatusOK, a.callStatusSnapshot())
}

type callStatusPayload struct {
	Active              *callRecord  `json:"active"`
	History             []callRecord `json:"history"`
	Polling             bool         `json:"polling"`
	EventDriven         bool         `json:"event_driven"`
	PollIntervalSeconds int          `json:"poll_interval_s"`
	LastPollError       string       `json:"last_poll_error"`
	Revision            uint64       `json:"revision"`
}

func (a *agent) callStatusSnapshot() callStatusPayload {
	a.mu.RLock()
	var active *callRecord
	if a.calls.Active != nil {
		copy := *a.calls.Active
		active = &copy
	}
	history := append([]callRecord(nil), a.calls.History...)
	lastError := a.calls.LastPollError
	eventDriven := a.calls.EventDriven
	revision := a.callRevision
	a.mu.RUnlock()
	if history == nil {
		history = []callRecord{}
	}
	return callStatusPayload{
		Active: active, History: history, Polling: true, EventDriven: eventDriven,
		PollIntervalSeconds: 5, LastPollError: lastError, Revision: revision,
	}
}

// callEvents holds one HTTP request until the call state changes or the bounded
// timeout expires. This replaces repeated background TCP connections from iOS.
func (a *agent) callEvents(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	after, err := strconv.ParseUint(request.URL.Query().Get("after"), 10, 64)
	if err != nil {
		writeError(response, http.StatusBadRequest, "通话事件游标无效")
		return
	}
	timeoutMS := 25_000
	if raw := request.URL.Query().Get("timeout_ms"); raw != "" {
		parsed, parseErr := strconv.Atoi(raw)
		if parseErr != nil || parsed < 100 || parsed > 30_000 {
			writeError(response, http.StatusBadRequest, "通话事件等待时间无效")
			return
		}
		timeoutMS = parsed
	}

	a.mu.RLock()
	revision := a.callRevision
	changed := a.callChanged
	a.mu.RUnlock()
	if after == revision {
		timer := time.NewTimer(time.Duration(timeoutMS) * time.Millisecond)
		defer timer.Stop()
		select {
		case <-changed:
		case <-timer.C:
		case <-request.Context().Done():
			return
		}
	}
	writeJSON(response, http.StatusOK, a.callStatusSnapshot())
}

type agentEventPayload struct {
	Revision    uint64            `json:"revision"`
	SMSRevision uint64            `json:"sms_revision"`
	SMSPending  int               `json:"sms_pending"`
	Call        callStatusPayload `json:"call"`
}

func (a *agent) agentEventSnapshot() agentEventPayload {
	a.mu.RLock()
	revision := a.eventRevision
	smsRevision := a.smsRevision
	smsPending := len(a.messages)
	a.mu.RUnlock()
	return agentEventPayload{
		Revision: revision, SMSRevision: smsRevision, SMSPending: smsPending,
		Call: a.callStatusSnapshot(),
	}
}

// agentEvents is the single background wait channel used by iOS. Call and SMS
// changes share one revision so an idle phone keeps only one USB HTTP request.
func (a *agent) agentEvents(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	after, err := strconv.ParseUint(request.URL.Query().Get("after"), 10, 64)
	if err != nil {
		writeError(response, http.StatusBadRequest, "事件游标无效")
		return
	}
	timeoutMS := 15_000
	if raw := request.URL.Query().Get("timeout_ms"); raw != "" {
		parsed, parseErr := strconv.Atoi(raw)
		if parseErr != nil || parsed < 100 || parsed > 30_000 {
			writeError(response, http.StatusBadRequest, "事件等待时间无效")
			return
		}
		timeoutMS = parsed
	}

	a.mu.RLock()
	revision := a.eventRevision
	changed := a.eventChanged
	a.mu.RUnlock()
	if after == revision {
		timer := time.NewTimer(time.Duration(timeoutMS) * time.Millisecond)
		defer timer.Stop()
		select {
		case <-changed:
		case <-timer.C:
		case <-request.Context().Done():
			return
		}
	}
	writeJSON(response, http.StatusOK, a.agentEventSnapshot())
}

// callHistoryAck 仅删除已被手机原子写入成功的通话记录，未确认记录继续留在交付队列。
func (a *agent) callHistoryAck(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		IDs []string `json:"ids"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	acknowledged := make(map[string]bool, len(body.IDs))
	for _, id := range body.IDs {
		if id != "" {
			acknowledged[id] = true
		}
	}

	a.mu.Lock()
	remaining := a.calls.History[:0]
	removed := 0
	for _, record := range a.calls.History {
		if acknowledged[record.ID] {
			removed++
			continue
		}
		remaining = append(remaining, record)
	}
	a.calls.History = remaining
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]int{"acknowledged": removed})
}

func (a *agent) dial(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Number string `json:"number"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	result, err := a.dialNumber(body.Number)
	if err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, result)
}

func (a *agent) dialNumber(raw string) (map[string]any, error) {
	number := normalizeDialNumber(raw)
	if number == "" || len(number) > 82 {
		return nil, errors.New("号码为空、过长或包含非法字符")
	}
	a.mu.RLock()
	active := a.calls.Active
	if active != nil {
		copy := *active
		active = &copy
	}
	a.mu.RUnlock()
	if active != nil && active.Direction == "outgoing" &&
		(active.Number == "" || normalizeDialNumber(active.Number) == number) &&
		(active.State == "dialing" || active.State == "alerting" || active.State == "active") {
		return map[string]any{"dialing": true, "number": number, "deduplicated": true}, nil
	}
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return nil, fmt.Errorf("create Android Telecom dial command: %w", err)
		}
		result := a.android.execute(context.Background(), androidCommand{
			ID: commandID, Action: "dial", Number: number,
		}, 12*time.Second)
		if !result.Success {
			return nil, errors.New(result.Error)
		}
		return map[string]any{"dialing": true, "number": number, "android_confirmed": true}, nil
	}
	response, err := a.at.command("ATD"+number+";", 8*time.Second)
	if err != nil {
		return nil, err
	}
	return map[string]any{"dialing": true, "number": number, "response": response}, nil
}

func normalizeDialNumber(raw string) string {
	var result strings.Builder
	for _, character := range strings.TrimSpace(raw) {
		switch {
		case character >= '0' && character <= '9', character == '+', character == '*', character == '#':
			result.WriteRune(character)
		case character == ' ', character == '-', character == '(', character == ')':
			// 仅忽略常见排版字符。
		default:
			return ""
		}
	}
	return result.String()
}

func (a *agent) answer(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if err := a.answerCall(); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"answered": true})
}

func (a *agent) answerCall() error {
	a.mu.Lock()
	if time.Since(a.calls.LastAnswerAt) < 2*time.Second {
		a.mu.Unlock()
		return nil
	}
	a.calls.LastAnswerAt = time.Now()
	a.mu.Unlock()
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return fmt.Errorf("create Android Telecom answer command: %w", err)
		}
		result := a.executeAndroidCallCommand(commandID, "answer")
		if !result.Success {
			return errors.New(result.Error)
		}
		return nil
	}
	appendVoiceSystemSnapshot("answer-before")
	if _, err := a.at.command("ATA", 5*time.Second); err != nil {
		appendVoiceSystemSnapshot("answer-failed")
		return err
	}
	appendVoiceSystemSnapshot("answer-after")
	return nil
}

func (a *agent) reject(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if err := a.rejectCall(); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"rejected": true})
}

func (a *agent) rejectCall() error {
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return fmt.Errorf("create Android Telecom reject command: %w", err)
		}
		result := a.executeAndroidCallCommand(commandID, "reject")
		if !result.Success {
			return errors.New(result.Error)
		}
		return nil
	}
	appendVoiceSystemSnapshot("reject-before")
	if _, err := a.at.command("AT+CHUP", 5*time.Second); err != nil {
		appendVoiceSystemSnapshot("reject-failed")
		return err
	}
	appendVoiceSystemSnapshot("reject-after")
	return nil
}

func (a *agent) hangup(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if err := a.hangupFlight.Do(a.hangupCall); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"hung_up": true})
}

func (a *agent) hangupCall() error {
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return fmt.Errorf("create Android Telecom hangup command: %w", err)
		}
		result := a.executeAndroidCallCommand(commandID, "end")
		if !result.Success {
			return errors.New(result.Error)
		}
		return nil
	}
	appendVoiceSystemSnapshot("hangup-before")
	if _, err := a.at.command("ATH", 5*time.Second); err != nil {
		if _, fallbackErr := a.at.command("AT+CHUP", 5*time.Second); fallbackErr != nil {
			appendVoiceSystemSnapshot("hangup-failed")
			return fallbackErr
		}
	}
	appendVoiceSystemSnapshot("hangup-after")
	return nil
}

var cloudHangupConfirmationDelays = []time.Duration{
	250 * time.Millisecond,
	500 * time.Millisecond,
	time.Second,
	2 * time.Second,
}

func hangupAndConfirmCall(
	command func(string, time.Duration) (string, error),
	sleep func(time.Duration),
	delays []time.Duration,
) (int, string, error) {
	if _, err := command("ATH", 5*time.Second); err != nil {
		if _, fallbackErr := command("AT+CHUP", 5*time.Second); fallbackErr != nil {
			return 0, "", fallbackErr
		}
	}
	lastCLCC := ""
	var lastErr error
	for index, delay := range delays {
		sleep(delay)
		response, err := command("AT+CLCC", 3*time.Second)
		lastCLCC = normalizeATText([]byte(response))
		if err != nil {
			lastErr = err
			continue
		}
		if len(parseCLCC(response)) == 0 {
			return index + 1, lastCLCC, nil
		}
		lastErr = errors.New("CLCC 仍报告活动语音通话")
	}
	if lastErr == nil {
		lastErr = errors.New("CLCC 未返回空闲状态")
	}
	return len(delays), lastCLCC, fmt.Errorf(
		"挂断 AT 已返回，但 CLCC 最终确认失败: %w；last_clcc=%q",
		lastErr, lastCLCC,
	)
}

func (a *agent) hangupCallConfirmed() (int, string, error) {
	appendVoiceSystemSnapshot("hangup-confirm-before")
	command := a.callControlCommand
	if command == nil {
		command = a.at.command
	}
	sleep := a.callControlSleep
	if sleep == nil {
		sleep = time.Sleep
	}
	delays := a.callControlDelays
	if len(delays) == 0 {
		delays = cloudHangupConfirmationDelays
	}
	attempts, lastCLCC, err := hangupAndConfirmCall(command, sleep, delays)
	if err != nil {
		appendVoiceSystemSnapshot("hangup-confirm-failed")
		return attempts, lastCLCC, err
	}
	a.applyCallPoll(nil, time.Now())
	appendVoiceSystemSnapshot("hangup-confirmed")
	return attempts, lastCLCC, nil
}

func (a *agent) dtmf(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Digit string `json:"digit"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if err := a.sendDTMFDigit(body.Digit); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(response, http.StatusOK, map[string]bool{"sent": true})
}

func (a *agent) sendDTMFDigit(digit string) error {
	if len(digit) != 1 || !strings.Contains("0123456789*#", digit) {
		return errors.New("DTMF 仅支持 0-9、*、#")
	}
	if a.profile.AndroidTelecom {
		commandID, err := randomUUID()
		if err != nil {
			return fmt.Errorf("create Android Telecom DTMF command: %w", err)
		}
		result := a.executeAndroidCallCommandWithNumber(commandID, "dtmf", digit)
		if !result.Success {
			return errors.New(result.Error)
		}
		return nil
	}
	if _, err := a.at.command(`AT+VTS="`+digit+`"`, 3*time.Second); err != nil {
		if _, fallbackErr := a.at.command("AT+CLDTMF=1,"+digit, 3*time.Second); fallbackErr != nil {
			return fallbackErr
		}
	}
	return nil
}

func (a *agent) mute(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Muted bool `json:"muted"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	value := "0"
	if body.Muted {
		value = "1"
	}
	if _, err := a.at.command("AT+CMUT="+value, 3*time.Second); err != nil {
		writeError(response, http.StatusBadGateway, err.Error())
		return
	}
	a.mu.Lock()
	a.muted = body.Muted
	a.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]bool{"muted": body.Muted})
}

func (a *agent) recording(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Action string `json:"action"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.Action != "start" && body.Action != "stop" {
		writeError(response, http.StatusBadRequest, "action 必须是 start 或 stop")
		return
	}
	// 模块代理不能伪造录音成功；后续由语音桥输出双向 PCM 后才开放此接口。
	a.unsupported(response, "模块侧双向 PCM 录音尚未接入")
}

func (a *agent) audioHostRegister(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if !decodeJSON(response, request, &body) {
		return
	}
	if body.Enabled {
		a.mu.RLock()
		callActive := a.calls.Active != nil && a.calls.Active.State == "active"
		a.mu.RUnlock()
		if !callActive {
			writeError(response, http.StatusConflict, "通话尚未接通，不能启动网络 PCM")
			return
		}
		a.voice.mu.Lock()
		a.voice.hostEnabled = true
		a.voice.mu.Unlock()
		go a.ensureVoiceRoute()
	} else {
		a.voice.mu.Lock()
		a.voice.hostEnabled = false
		a.voice.mu.Unlock()
		go a.stopVoiceRoute()
	}
	writeJSON(response, http.StatusOK, map[string]bool{"enabled": body.Enabled})
}

// audioHostWarmup 只提前加载语音驱动和校准，不打开 D4/D5/D6 媒体路由。
// 拨号或锁屏来电阶段可以安全执行，真正接通后仍由 audioHostRegister 启动完整 PCM 桥。
func (a *agent) audioHostWarmup(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	a.mu.RLock()
	hasCall := a.calls.Active != nil
	a.mu.RUnlock()
	if !hasCall {
		writeError(response, http.StatusConflict, "当前没有进行中的通话，不能预热语音运行时")
		return
	}
	go a.ensureVoiceRuntimeWarm()
	writeJSON(response, http.StatusOK, map[string]bool{"warming": true})
}

func (a *agent) audioHostConfig(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	snapshot := a.voice.snapshot()
	routeReady := snapshot.Ready
	routeSessionReady := snapshot.RouteReady
	routeError := snapshot.LastError
	routeRunning := snapshot.Starting || snapshot.Command != nil || snapshot.RouteCommand != nil
	helperPID := 0
	if snapshot.Command != nil && snapshot.Command.Process != nil {
		helperPID = snapshot.Command.Process.Pid
	}
	routeHelperPID := 0
	if snapshot.RouteCommand != nil && snapshot.RouteCommand.Process != nil {
		routeHelperPID = snapshot.RouteCommand.Process.Pid
	}
	startedAt := snapshot.StartedAt
	logOffset := snapshot.LogOffset
	stats, statsAvailable, logTail := voiceDiagnosticSnapshot(logOffset)
	startedAtText := ""
	if !startedAt.IsZero() {
		startedAtText = startedAt.UTC().Format(time.RFC3339Nano)
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"vendor_id": 0x2c7c, "product_id": 0x0125, "location_id": 0,
		"transport": "tcp_pcm_s16le", "host": "192.168.225.1", "port": 7580,
		"sample_rate": 8000, "channels": 1,
		"route_ready": routeReady, "route_listening": snapshot.Listening,
		"route_error":   routeError,
		"route_running": routeRunning, "helper_pid": helperPID,
		"route_starting":      snapshot.Starting,
		"route_session_ready": routeSessionReady, "route_helper_pid": routeHelperPID,
		"session_started_at":   startedAtText,
		"statistics_available": statsAvailable, "statistics": stats,
		"diagnostic_log": voiceRouteLogFile, "log_tail": logTail,
	})
}
