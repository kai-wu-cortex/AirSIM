package main

import (
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestCloudCommandURLPinsAgentID(t *testing.T) {
	registration := pushRegistration{RelayURL: "https://relay.example", DeviceID: "apple-test", DeviceSecret: "test-only-secret", AndroidAgentID: "安卓-A:slot/1?%"}
	endpoint, err := cloudCommandURL(registration)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Path != "/v2/devices/apple-test/commands/connect" || u.Query().Get("agent_id") != registration.AndroidAgentID {
		t.Fatal("agent not pinned")
	}
	for _, id := range []string{"", " ", "x\n", strings.Repeat("中", 43), string([]byte{0xff})} {
		registration.AndroidAgentID = id
		if _, err := cloudCommandURL(registration); err == nil {
			t.Fatal("invalid identity accepted")
		}
	}
}

func TestWrongCommandTargetBeforeExecution(t *testing.T) {
	a := &agent{push: &pushManager{config: pushRegistration{AndroidAgentID: "android-B"}}}
	result := a.executeCloudCommand(cloudDeviceCommand{CommandID: "c87f982a-1750-4f03-9a96-6553e454f522", TargetAgentID: "android-A", Type: "dial", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano)})
	if result.Status != "failed" || result.Error != "command_target_mismatch" {
		t.Fatal("wrong target reached executor")
	}
}

func TestCommandCloseRedactsReason(t *testing.T) {
	err := decodeCloudPeerClose([]byte{15, 161, 's', 'e', 'c', 'r', 'e', 't'})
	close, ok := err.(*cloudPeerClose)
	if !ok || close.Code != 4001 || close.Category() != "replaced" || strings.Contains(err.Error(), "secret") {
		t.Fatal("close reason lost or exposed")
	}
	for _, b := range [][]byte{{3}, {3, 237}, {3, 232, 0xc0, 0x80}} {
		if _, ok := decodeCloudPeerClose(b).(*cloudPeerClose); ok {
			t.Fatal("invalid frame accepted")
		}
	}
	if cloudCommandErrorDelay(1, close) < time.Minute {
		t.Fatal("replacement retry amplified")
	}
	if cloudCommandErrorDelay(1, &relayCommandHTTPError{Status: 429, RetryAfter: 10 * time.Minute}) < 10*time.Minute {
		t.Fatal("retry-after shortened")
	}
}

func TestCommandFallbackRespectsSocketAndCooldown(t *testing.T) {
	p := &pushManager{}
	now := time.Now()
	if !p.beginCommandPull(now) || p.beginCommandPull(now.Add(time.Second)) {
		t.Fatal("fallback rate gate")
	}
	p.mu.Lock()
	p.commandConnected = true
	p.mu.Unlock()
	if p.beginCommandPull(now.Add(time.Minute)) {
		t.Fatal("HTTP pull while WSS online")
	}
	p.mu.Lock()
	p.commandConnected = false
	p.mu.Unlock()
	p.commandFailed(1, &relayCommandHTTPError{Status: 429, RetryAfter: 10 * time.Minute})
	if p.beginCommandPull(now.Add(time.Minute)) {
		t.Fatal("HTTP bypassed WSS cooldown")
	}
}

func TestStaleDTMFNeverReachesAnotherCall(t *testing.T) {
	a := &agent{cloudCallCurrent: &cloudCallDescriptor{CallID: "new-call", CallUUID: "d87f982a-1750-4f03-9a96-6553e454f522", Generation: 2}}
	result := a.executeCloudCommand(cloudDeviceCommand{CommandID: "c87f982a-1750-4f03-9a96-6553e454f522", Type: "dtmf", Number: "1", Owner: "iphone", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano), Call: &cloudCommandCall{CallID: "old-call", CallUUID: "e87f982a-1750-4f03-9a96-6553e454f522", Generation: 1}})
	if result.Status != "failed" || !strings.Contains(result.Error, "不属于当前通话") {
		t.Fatal("stale tone reached modem executor")
	}
}
