package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoadAndroidControlTokenPrefersProtectedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("file-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	token, err := loadAndroidControlToken(func(key string) string {
		switch key {
		case androidControlTokenFileEnvironment:
			return path
		case androidControlTokenEnvironment:
			return "environment-secret"
		default:
			return ""
		}
	})
	if err != nil || token != "file-secret" {
		t.Fatalf("token=%q err=%v", token, err)
	}
}

func TestAndroidControlRequiresBearerToken(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())

	request := httptest.NewRequest(http.MethodGet, "/api/android/status", nil)
	request.RemoteAddr = "10.185.5.63:41000"
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("missing token status=%d body=%s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodGet, "/api/android/status", nil)
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("valid token status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAndroidPairRegistrationStoresValidatedPushIdentityWithoutEchoingSecrets(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	a.pairRegistrationSync = func() {}
	handler := a.routes(testLogger())
	registration := `{
		"cloud_enabled":true,"device_id":"iphone-air-12345678",
		"device_secret":"0123456789abcdef0123456789abcdef",
		"voip_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"alert_token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"bundle_id":"com.eric3u.airsim","environment":"production",
		"relay_url":"https://push.example.com","media_transport":"legacy_pcm"
	}`
	request := httptest.NewRequest(http.MethodPost, "/api/android/pair/register", strings.NewReader(registration))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("pair registration status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "0123456789abcdef") || strings.Contains(response.Body.String(), "aaaaaaaa") {
		t.Fatalf("pair response leaked credentials: %s", response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"device_id_hint":"…12345678"`) {
		t.Fatalf("pair response missing safe identity hint: %s", response.Body.String())
	}
	status := a.push.status()
	if !status.Configured || !status.CallPushReady || !status.MessagePushReady {
		t.Fatalf("pair registration was not stored: %#v", status)
	}
}

func TestAndroidPairRegistrationRejectsInvalidIdentity(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	a.pairRegistrationSync = func() {}
	handler := a.routes(testLogger())
	request := httptest.NewRequest(http.MethodPost, "/api/android/pair/register", strings.NewReader(`{"device_id":"x"}`))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || a.push.status().Configured {
		t.Fatalf("invalid pair registration status=%d configured=%v", response.Code, a.push.status().Configured)
	}
}

func TestAndroidCallEventDrivesSharedCallTracker(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())
	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-1","call_id":"telecom-7","direction":"incoming",
		"state":"incoming","number":"+86 13800138000","mode":"remote_silent"
	}`)

	a.mu.RLock()
	if a.calls.Active == nil || a.calls.Active.AndroidID != "telecom-7" ||
		a.calls.Active.State != "incoming" || a.calls.Active.Direction != "incoming" {
		t.Fatalf("unexpected active call: %#v", a.calls.Active)
	}
	firstID := a.calls.Active.ID
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-2","call_id":"telecom-7","direction":"incoming",
		"state":"active","number":"+86 13800138000","mode":"remote_silent"
	}`)
	a.mu.RLock()
	if a.calls.Active == nil || a.calls.Active.ID != firstID || a.calls.Active.State != "active" {
		t.Fatalf("active transition lost identity: %#v", a.calls.Active)
	}
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-3","call_id":"telecom-7","direction":"incoming",
		"state":"ended","mode":"remote_silent"
	}`)
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.calls.Active != nil || len(a.calls.History) != 1 || a.calls.History[0].ID != firstID {
		t.Fatalf("ended transition incorrect: active=%#v history=%#v", a.calls.Active, a.calls.History)
	}
}

func TestAndroidCommandWaitsForMatchingAcknowledgement(t *testing.T) {
	control := newAndroidControl("secret-value")
	resultChannel := make(chan androidCommandResult, 1)
	go func() {
		resultChannel <- control.execute(context.Background(), androidCommand{
			ID: "command-1", Action: "answer", CallID: "telecom-7",
		}, time.Second)
	}()

	command, ok := control.next(context.Background(), time.Second)
	if !ok || command.ID != "command-1" || command.Action != "answer" {
		t.Fatalf("unexpected command: ok=%v command=%#v", ok, command)
	}
	select {
	case result := <-resultChannel:
		t.Fatalf("command completed before Android acknowledgement: %#v", result)
	default:
	}
	if err := control.complete(androidCommandResult{ID: "stale", Success: true}); err == nil {
		t.Fatal("stale acknowledgement must be rejected")
	}
	if err := control.complete(androidCommandResult{ID: "command-1", Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-resultChannel:
		if !result.Success || result.ID != "command-1" {
			t.Fatalf("unexpected result: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("matching acknowledgement did not release command")
	}
}

func TestAndroidCommandTimesOutAndIsRemoved(t *testing.T) {
	control := newAndroidControl("secret-value")
	result := control.execute(context.Background(), androidCommand{ID: "command-timeout", Action: "end"}, 10*time.Millisecond)
	if result.Success || !strings.Contains(result.Error, "timeout") {
		t.Fatalf("unexpected timeout result: %#v", result)
	}
	if err := control.complete(androidCommandResult{ID: "command-timeout", Success: true}); err == nil {
		t.Fatal("late acknowledgement must be rejected")
	}
}

func TestAndroidProfileSMSSendUsesTelephonyInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	resultChannel := make(chan struct {
		segments int
		err      error
	}, 1)
	go func() {
		segments, err := a.sendSMSMessage("+86 13800138000", "第一段\n第二段")
		resultChannel <- struct {
			segments int
			err      error
		}{segments: segments, err: err}
	}()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "send_sms" || command.Number != "+8613800138000" || command.Message != "第一段\n第二段" {
		t.Fatalf("Android SMS was not routed to Telephony: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true, Segments: 2}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-resultChannel:
		if result.err != nil || result.segments != 2 {
			t.Fatalf("unexpected Android SMS result: segments=%d err=%v", result.segments, result.err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android SMS did not finish after Telephony acknowledgement")
	}
}

func TestAndroidIncomingSMSEventFeedsSharedQueueAndDeduplicates(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())
	body := `{
		"event_id":"sms-event-7","delivery_id":"android-sms-7",
		"sender":"10010","content":"验证码 246810",
		"timestamp":"2026-09-23T10:20:30.123Z"
	}`
	postAndroidJSON(t, handler, "/api/android/sms/event", body)

	a.mu.RLock()
	if len(a.messages) != 1 || a.messages[0].Memory != "ANDROID" ||
		a.messages[0].Message.Sender != "10010" ||
		a.messages[0].Message.Content != "验证码 246810" ||
		a.messages[0].Message.Code != "246810" ||
		a.messages[0].Message.DeliveryID != "android-sms-7" {
		t.Fatalf("unexpected Android SMS queue: %#v", a.messages)
	}
	firstRevision := a.smsRevision
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/sms/event", body)
	a.mu.RLock()
	defer a.mu.RUnlock()
	if len(a.messages) != 1 || a.smsRevision != firstRevision {
		t.Fatalf("duplicate Android SMS was re-enqueued: count=%d revision=%d->%d", len(a.messages), firstRevision, a.smsRevision)
	}
}

func TestAndroidProfileDialUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	resultChannel := make(chan struct {
		value map[string]any
		err   error
	}, 1)
	go func() {
		value, err := a.dialNumber("10086")
		resultChannel <- struct {
			value map[string]any
			err   error
		}{value: value, err: err}
	}()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "dial" || command.Number != "10086" || command.CallID != "" {
		t.Fatalf("Android dial was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	select {
	case result := <-resultChannel:
		if result.err != nil || result.value["dialing"] != true || result.value["number"] != "10086" {
			t.Fatalf("unexpected Android dial result: value=%#v err=%v", result.value, result.err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android dial did not finish after Telecom acknowledgement")
	}
}

func TestAndroidProfileHangupUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-9", AndroidID: "telecom-9", Direction: "outgoing", State: "active",
	}
	result := make(chan error, 1)
	go func() { result <- a.hangupCall() }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "end" || command.CallID != "telecom-9" {
		t.Fatalf("Android hangup was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android hangup did not finish after Telecom acknowledgement")
	}
}

func TestAndroidProfileAnswerUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-answer", AndroidID: "telecom-answer", Direction: "incoming", State: "incoming",
	}
	result := make(chan error, 1)
	go func() { result <- a.answerCall() }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "answer" || command.CallID != "telecom-answer" {
		t.Fatalf("Android answer was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	a.applyAndroidCallEvent(androidCallEvent{
		EventID: "event-answer-active", CallID: "telecom-answer", Direction: "incoming", State: "active",
	}, time.Now())
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android answer did not finish after Telecom acknowledgement")
	}
}

func TestAndroidProfileRejectUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-reject", AndroidID: "telecom-reject", Direction: "incoming", State: "incoming",
	}
	result := make(chan error, 1)
	go func() { result <- a.rejectCall() }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "reject" || command.CallID != "telecom-reject" {
		t.Fatalf("Android reject was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android reject did not finish after Telecom acknowledgement")
	}
}

func TestAndroidProfileDTMFUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-10", AndroidID: "telecom-10", Direction: "outgoing", State: "active",
	}
	result := make(chan error, 1)
	go func() { result <- a.sendDTMFDigit("5") }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "dtmf" || command.CallID != "telecom-10" || command.Number != "5" {
		t.Fatalf("Android DTMF was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android DTMF did not finish after Telecom acknowledgement")
	}
}

func TestCloudAnswerUsesAndroidTelecomAndWaitsForResult(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "agent-call-7", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 2, Direction: "incoming",
	}
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: descriptor.CallID, AndroidID: "telecom-7", Direction: "incoming", State: "incoming",
	}
	a.cloudCallCurrent = &descriptor
	results := make(chan cloudCommandResult, 1)
	go func() {
		results <- a.executeCloudCommand(cloudDeviceCommand{
			CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
			Type:      "call_control", Action: "answer", Owner: "iphone",
			ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
			Call: &cloudCommandCall{
				CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
				Generation: descriptor.Generation, Direction: descriptor.Direction,
			},
		})
	}()
	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "answer" || command.CallID != "telecom-7" {
		t.Fatalf("cloud command was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	select {
	case result := <-results:
		t.Fatalf("cloud result completed before Telecom acknowledgement: %#v", result)
	default:
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	select {
	case result := <-results:
		t.Fatalf("cloud result completed before Android reported active: %#v", result)
	default:
	}
	a.applyAndroidCallEvent(androidCallEvent{
		EventID: "event-active", CallID: "telecom-7", Direction: "incoming", State: "active",
	}, time.Now())
	select {
	case result := <-results:
		if result.Status != "completed" || result.Result["answered"] != true {
			t.Fatalf("unexpected cloud result: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("cloud command did not complete after Android reported active")
	}
}

func TestIncomingCloudMediaAnswerUsesAndroidTelecomAndWaitsForActive(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-8", AndroidID: "telecom-8", Direction: "incoming", State: "incoming",
	}
	result := make(chan error, 1)
	go func() {
		result <- a.executeIncomingCloudCallAction(cloudCallAction{
			Action: "answer", CallID: "agent-call-8",
			CommandID: "dc7c37df-ae31-4d4b-aef4-893a92c58c86", Owner: "iphone",
		}, "answer")
	}()
	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "answer" || command.CallID != "telecom-8" {
		t.Fatalf("media answer was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	select {
	case err := <-result:
		t.Fatalf("media answer completed before Android active: %v", err)
	default:
	}
	a.applyAndroidCallEvent(androidCallEvent{
		EventID: "event-media-active", CallID: "telecom-8", Direction: "incoming", State: "active",
	}, time.Now())
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("media answer did not complete after Android active")
	}
}

func testAndroidAgent(token string) *agent {
	a := newAgent(atDevice)
	a.profile = runtimeProfileFrom("android-avf")
	a.android = newAndroidControl(token)
	a.push = nil
	return a
}

func postAndroidJSON(t *testing.T, handler http.Handler, path, body string) {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("POST %s status=%d body=%s", path, response.Code, response.Body.String())
	}
}
