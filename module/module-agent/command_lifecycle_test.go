package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestPendingHTTPBatchCannotExecuteAfterConfigurationChange(t *testing.T) {
	for _, change := range []string{"disabled", "device", "secret", "relay"} {
		t.Run(change, func(t *testing.T) {
			entered := make(chan struct{})
			resume := make(chan struct{})
			done := make(chan error, 1)
			var completions atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v2/commands/pull" {
					close(entered)
					<-resume
					_ = json.NewEncoder(w).Encode(map[string]any{"commands": []cloudDeviceCommand{{CommandID: "c87f982a-1750-4f03-9a96-6553e454f522", TargetAgentID: "android-test", Type: "unsupported-fixture", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano)}}})
				} else {
					completions.Add(1)
					w.WriteHeader(202)
				}
			}))
			defer server.Close()
			p := &pushManager{config: testPushRegistration(server.URL), client: server.Client()}
			a := &agent{push: p}
			go func() { done <- a.syncCloudCommandsOnce() }()
			select {
			case <-entered:
			case <-time.After(2 * time.Second):
				t.Fatal("pull did not start")
			}
			p.mu.Lock()
			switch change {
			case "disabled":
				disabled := false
				p.config.CloudEnabled = &disabled
			case "device":
				p.config.DeviceID = "new-apple"
			case "secret":
				p.config.DeviceSecret = "new-test-only-secret"
			case "relay":
				p.config.RelayURL = "https://new-relay.example"
			}
			p.mu.Unlock()
			close(resume)
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("batch stalled")
			}
			if completions.Load() != 0 || len(a.cloudCommandResults) != 0 {
				t.Fatal("retired HTTP batch executed or completed")
			}
		})
	}
}

func TestQueuedExecutorChecksConfigurationAfterLock(t *testing.T) {
	p := &pushManager{config: testPushRegistration("https://relay.example")}
	original, _ := p.commandRegistration()
	a := &agent{push: p}
	a.cloudCommandExecMu.Lock()
	done := make(chan cloudCommandResult, 1)
	go func() {
		done <- a.executeCloudCommandFor(cloudDeviceCommand{CommandID: "c87f982a-1750-4f03-9a96-6553e454f522", TargetAgentID: "android-test", Type: "unsupported-fixture", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano)}, &original)
	}()
	p.mu.Lock()
	p.config.DeviceSecret = "new-test-only-secret"
	p.mu.Unlock()
	a.cloudCommandExecMu.Unlock()
	result := <-done
	if result.Error != "command_configuration_changed" || len(a.cloudCommandResults) != 0 {
		t.Fatal("queued execution used old configuration")
	}
}

func TestCommandEpochRejectsABAAndIgnoresMetadata(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	reg := testPushRegistration("https://relay.example")
	if err := p.store(reg); err != nil {
		t.Fatal(err)
	}
	original, _ := p.commandRegistration()
	reg.AndroidPhoneNumber = "synthetic-sim-metadata"
	if err := p.store(reg); err != nil {
		t.Fatal(err)
	}
	current, _ := p.commandRegistration()
	if !sameCommandRegistration(original, current) {
		t.Fatal("metadata reconnected command scope")
	}
	if err := p.setCloudEnabled(false); err != nil {
		t.Fatal(err)
	}
	if err := p.setCloudEnabled(true); err != nil {
		t.Fatal(err)
	}
	current, _ = p.commandRegistration()
	if sameCommandRegistration(original, current) {
		t.Fatal("old epoch revived after off/on")
	}
	if p.commandFailedFor(&original, 1, &relayCommandHTTPError{Status: 429}) != 0 {
		t.Fatal("old failure cooled new configuration")
	}
}
