package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const androidControlTokenEnvironment = "DJONEHUB_ANDROID_CONTROL_TOKEN"
const androidControlTokenFileEnvironment = "DJONEHUB_ANDROID_CONTROL_TOKEN_FILE"

func loadAndroidControlToken(getenv func(string) string) (string, error) {
	if path := strings.TrimSpace(getenv(androidControlTokenFileEnvironment)); path != "" {
		value, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read Android control token: %w", err)
		}
		return strings.TrimSpace(string(value)), nil
	}
	return strings.TrimSpace(getenv(androidControlTokenEnvironment)), nil
}

type androidCommand struct {
	ID      string `json:"id"`
	Action  string `json:"action"`
	CallID  string `json:"call_id,omitempty"`
	Number  string `json:"number,omitempty"`
	Message string `json:"message,omitempty"`
}

type androidCommandResult struct {
	ID       string `json:"id"`
	Success  bool   `json:"success"`
	Error    string `json:"error,omitempty"`
	Segments int    `json:"segments,omitempty"`
}

type androidCallEvent struct {
	EventID   string `json:"event_id"`
	CallID    string `json:"call_id"`
	Direction string `json:"direction"`
	State     string `json:"state"`
	Number    string `json:"number,omitempty"`
	Mode      string `json:"mode,omitempty"`
}

type androidSMSEvent struct {
	EventID    string `json:"event_id"`
	DeliveryID string `json:"delivery_id"`
	Sender     string `json:"sender"`
	Content    string `json:"content"`
	Timestamp  string `json:"timestamp"`
}

type androidPendingCommand struct {
	result chan androidCommandResult
}

type androidControl struct {
	token      string
	queue      chan androidCommand
	mu         sync.Mutex
	pending    map[string]*androidPendingCommand
	seenEvents map[string]time.Time
	lastSeen   time.Time
}

func newAndroidControl(token string) *androidControl {
	return &androidControl{
		token: strings.TrimSpace(token), queue: make(chan androidCommand),
		pending: make(map[string]*androidPendingCommand), seenEvents: make(map[string]time.Time),
	}
}

func (control *androidControl) configured() bool {
	return control != nil && control.token != ""
}

func (control *androidControl) authorized(header string) bool {
	if !control.configured() {
		return false
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return false
	}
	provided := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	return len(provided) == len(control.token) && subtle.ConstantTimeCompare([]byte(provided), []byte(control.token)) == 1
}

func (control *androidControl) touch() {
	control.mu.Lock()
	control.lastSeen = time.Now()
	control.mu.Unlock()
}

func (control *androidControl) execute(ctx context.Context, command androidCommand, timeout time.Duration) androidCommandResult {
	if control == nil || !control.configured() {
		return androidCommandResult{ID: command.ID, Error: "android control unavailable"}
	}
	if command.ID == "" {
		return androidCommandResult{Error: "android command id is empty"}
	}
	pending := &androidPendingCommand{result: make(chan androidCommandResult, 1)}
	control.mu.Lock()
	if _, exists := control.pending[command.ID]; exists {
		control.mu.Unlock()
		return androidCommandResult{ID: command.ID, Error: "android command already pending"}
	}
	control.pending[command.ID] = pending
	control.mu.Unlock()
	defer func() {
		control.mu.Lock()
		delete(control.pending, command.ID)
		control.mu.Unlock()
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case control.queue <- command:
	case <-ctx.Done():
		return androidCommandResult{ID: command.ID, Error: ctx.Err().Error()}
	case <-timer.C:
		return androidCommandResult{ID: command.ID, Error: "android command delivery timeout"}
	}
	select {
	case result := <-pending.result:
		return result
	case <-ctx.Done():
		return androidCommandResult{ID: command.ID, Error: ctx.Err().Error()}
	case <-timer.C:
		return androidCommandResult{ID: command.ID, Error: "android command acknowledgement timeout"}
	}
}

func (control *androidControl) next(ctx context.Context, wait time.Duration) (androidCommand, bool) {
	if control == nil || !control.configured() {
		return androidCommand{}, false
	}
	control.touch()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case command := <-control.queue:
		return command, true
	case <-ctx.Done():
		return androidCommand{}, false
	case <-timer.C:
		return androidCommand{}, false
	}
}

func (control *androidControl) complete(result androidCommandResult) error {
	if control == nil || result.ID == "" {
		return errors.New("android command result id is empty")
	}
	control.mu.Lock()
	pending, exists := control.pending[result.ID]
	if exists {
		delete(control.pending, result.ID)
		control.lastSeen = time.Now()
	}
	control.mu.Unlock()
	if !exists {
		return errors.New("android command is not pending")
	}
	pending.result <- result
	return nil
}

func (control *androidControl) observeEvent(eventID string) bool {
	now := time.Now()
	control.mu.Lock()
	defer control.mu.Unlock()
	control.lastSeen = now
	for id, observed := range control.seenEvents {
		if now.Sub(observed) > 10*time.Minute {
			delete(control.seenEvents, id)
		}
	}
	if _, exists := control.seenEvents[eventID]; exists {
		return false
	}
	control.seenEvents[eventID] = now
	return true
}

func (a *agent) requireAndroidControl(response http.ResponseWriter, request *http.Request) bool {
	if !a.profile.AndroidTelecom || a.android == nil || !a.android.configured() {
		writeError(response, http.StatusServiceUnavailable, "Android Telecom 控制未配置")
		return false
	}
	if !a.android.authorized(request.Header.Get("Authorization")) {
		response.Header().Set("WWW-Authenticate", "Bearer")
		writeError(response, http.StatusUnauthorized, "Android 控制鉴权失败")
		return false
	}
	return true
}

func (a *agent) androidStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) || !a.requireAndroidControl(response, request) {
		return
	}
	a.android.mu.Lock()
	lastSeen, pending := a.android.lastSeen, len(a.android.pending)
	a.android.mu.Unlock()
	writeJSON(response, http.StatusOK, map[string]any{
		"ok": true, "runtime_profile": a.profile.Name, "pending_commands": pending,
		"last_seen": lastSeen,
	})
}

func (a *agent) androidCallEvent(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) || !a.requireAndroidControl(response, request) {
		return
	}
	var event androidCallEvent
	if !decodeJSON(response, request, &event) {
		return
	}
	if err := validateAndroidCallEvent(event); err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	if !a.android.observeEvent(event.EventID) {
		writeJSON(response, http.StatusOK, map[string]bool{"accepted": true, "duplicate": true})
		return
	}
	a.applyAndroidCallEvent(event, time.Now())
	a.debug.add("android-telecom", "event", "Android Telecom 通话状态", event.State, map[string]string{
		"event_id": event.EventID, "call_id": event.CallID, "direction": event.Direction, "mode": event.Mode,
	})
	writeJSON(response, http.StatusOK, map[string]bool{"accepted": true})
}

func (a *agent) androidSMSEvent(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) || !a.requireAndroidControl(response, request) {
		return
	}
	var event androidSMSEvent
	if !decodeJSON(response, request, &event) {
		return
	}
	timestamp, err := validateAndroidSMSEvent(event)
	if err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	if !a.android.observeEvent(event.EventID) {
		writeJSON(response, http.StatusOK, map[string]bool{"accepted": true, "duplicate": true})
		return
	}
	code := ""
	if match := verificationCodePattern.FindStringSubmatch(event.Content); len(match) == 2 {
		code = match[1]
	}
	a.mergeSMS([]storedSMS{{Memory: "ANDROID", Message: smsMessage{
		Sender: event.Sender, Content: event.Content, Code: code,
		Timestamp: timestamp, DeliveryID: event.DeliveryID,
	}}})
	a.debug.add("android-sms", "event", "Android 系统短信已进入交付队列", "", map[string]string{
		"event_id": event.EventID, "delivery_id": event.DeliveryID,
	})
	writeJSON(response, http.StatusOK, map[string]bool{"accepted": true})
}

func validateAndroidSMSEvent(event androidSMSEvent) (time.Time, error) {
	if strings.TrimSpace(event.EventID) == "" || len(event.EventID) > 128 ||
		strings.TrimSpace(event.DeliveryID) == "" || len(event.DeliveryID) > 128 {
		return time.Time{}, errors.New("Android 短信事件标识无效")
	}
	if strings.TrimSpace(event.Sender) == "" || len(event.Sender) > 128 ||
		strings.TrimSpace(event.Content) == "" || len([]rune(event.Content)) > 2000 {
		return time.Time{}, errors.New("Android 短信内容无效")
	}
	timestamp, err := time.Parse(time.RFC3339Nano, event.Timestamp)
	if err != nil {
		return time.Time{}, errors.New("Android 短信时间无效")
	}
	return timestamp, nil
}

func (a *agent) androidPairRegister(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) || !a.requireAndroidControl(response, request) {
		return
	}
	if a.push == nil {
		writeError(response, http.StatusServiceUnavailable, "Push 管理器不可用")
		return
	}
	var registration pushRegistration
	if !decodeJSON(response, request, &registration) {
		return
	}
	if err := a.push.store(registration); err != nil {
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	deviceID := strings.TrimSpace(registration.DeviceID)
	hint := deviceID
	if len(hint) > 8 {
		hint = "…" + hint[len(hint)-8:]
	}
	a.debug.add("android-pair", "completed", "iOS Push 身份已安全写入 Agent", "", map[string]string{
		"device_id_hint": hint,
	})
	if a.pairRegistrationSync != nil {
		go a.pairRegistrationSync()
	}
	writeJSON(response, http.StatusOK, map[string]any{
		"configured": true, "device_id_hint": hint,
	})
}

func validateAndroidCallEvent(event androidCallEvent) error {
	if strings.TrimSpace(event.EventID) == "" || len(event.EventID) > 128 || strings.TrimSpace(event.CallID) == "" || len(event.CallID) > 128 {
		return errors.New("Android 通话事件标识无效")
	}
	if event.Direction != "incoming" && event.Direction != "outgoing" {
		return errors.New("Android 通话方向无效")
	}
	switch event.State {
	case "incoming", "dialing", "alerting", "active", "held", "ended":
	default:
		return errors.New("Android 通话状态无效")
	}
	if event.Mode != "" && event.Mode != "remote_silent" && event.Mode != "local_and_push" {
		return errors.New("Android 通话显示模式无效")
	}
	if len(event.Number) > 128 {
		return errors.New("Android 通话号码过长")
	}
	return nil
}

func (a *agent) androidCommandNext(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) || !a.requireAndroidControl(response, request) {
		return
	}
	wait := 25
	if raw := request.URL.Query().Get("wait"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed >= 0 && parsed <= 30 {
			wait = parsed
		}
	}
	command, ok := a.android.next(request.Context(), time.Duration(wait)*time.Second)
	if !ok {
		response.WriteHeader(http.StatusNoContent)
		return
	}
	a.debug.add("android-telecom", "command", "向 Android 下发 Telecom 命令", command.Action, map[string]string{
		"command_id": command.ID, "call_id": command.CallID,
	})
	writeJSON(response, http.StatusOK, command)
}

func (a *agent) androidCommandResult(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) || !a.requireAndroidControl(response, request) {
		return
	}
	var result androidCommandResult
	if !decodeJSON(response, request, &result) {
		return
	}
	if err := a.android.complete(result); err != nil {
		writeError(response, http.StatusConflict, err.Error())
		return
	}
	a.debug.add("android-telecom", "result", "Android Telecom 命令完成", fmt.Sprintf("success=%v", result.Success), map[string]string{
		"command_id": result.ID,
	})
	writeJSON(response, http.StatusOK, map[string]bool{"accepted": true})
}
