package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type retryCancelTransport struct {
	started chan struct{}
	sends   atomic.Int32
}

func (r *retryCancelTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if r.sends.Add(1) == 1 {
		close(r.started)
	}
	return nil, errors.New("synthetic transient failure")
}

// A queued retry must not become a fresh request after an enter/exit cycle.
func TestSMSRetryCannotReviveAfterLocalModeExit(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	p.config = pushRegistration{RelayURL: "https://fixture.invalid", AlertToken: "fixture"}
	transport := &retryCancelTransport{started: make(chan struct{})}
	p.client = &http.Client{Transport: transport}
	a := &agent{push: p}
	a.scheduleSMSPush(smsMessage{DeliveryID: "fixture-sms", Content: "synthetic"})
	select {
	case <-transport.started:
	case <-time.After(time.Second):
		t.Fatal("first attempt missing")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := p.relayGate.disableAndDrain(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.relayGate.enable(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2200 * time.Millisecond)
	if got := transport.sends.Load(); got != 1 {
		t.Fatalf("old SMS retry revived: sends=%d", got)
	}
}

func TestCloudCommandRejectedAtActionBoundaryWhenLocal(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	p.config.AndroidAgentID = "fixture-agent"
	if err := p.relayGate.disableAndDrain(context.Background()); err != nil {
		t.Fatal(err)
	}
	a := &agent{push: p}
	result := a.executeCloudCommand(cloudDeviceCommand{TargetAgentID: "fixture-agent"})
	if result.Error != "pure_local_relay_disabled" {
		t.Fatalf("action admission missing: %#v", result)
	}
}

func TestCommandGenerationRejectsOldResultsButAllowsNewBackoff(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	p.config = testPushRegistration("https://fixture.invalid")
	old, _ := p.commandRegistration()
	if err := p.relayGate.disableAndDrain(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := p.relayGate.enable(); err != nil {
		t.Fatal(err)
	}
	transport := &pureLocalCountingTransport{}
	p.client = &http.Client{Transport: transport}
	if err := p.completeCommandFor(old, cloudCommandResult{}); err == nil || transport.sends != 0 {
		t.Fatal("old result uploaded after restore")
	}
	current, _ := p.commandRegistration()
	if p.commandFailedFor(&current, 1, errors.New("synthetic")) <= 0 {
		t.Fatal("new generation lost retry backoff")
	}
}

func TestRelayEgressCancellationAndLateGeneration(t *testing.T) {
	g := newRelayEgress(false)
	generation := g.generation()
	ctx, release, err := g.acquire(context.Background(), generation)
	if err != nil {
		t.Fatal(err)
	}
	deadline, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()
	if g.disableAndDrain(deadline) == nil {
		t.Fatal("acknowledged an unfinished operation")
	}
	if ctx.Err() == nil {
		t.Fatal("operation not cancelled")
	}
	if g.enable() == nil {
		t.Fatal("enabled while draining")
	}
	release()
	if err := g.disableAndDrain(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := g.enable(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := g.acquire(context.Background(), generation); err == nil {
		t.Fatal("old operation revived")
	}
	_, finish, err := g.acquire(context.Background(), g.generation())
	if err != nil {
		t.Fatal(err)
	}
	finish()
}

type pureLocalCountingTransport struct{ sends int }

func (r *pureLocalCountingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	r.sends++
	return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("{}")), Request: req}, nil
}
func TestPushClientRespectsPureLocalAdmission(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	transport := &pureLocalCountingTransport{}
	client := &http.Client{Transport: transport}
	if err := p.relayGate.disableAndDrain(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := p.postJSON(client, "https://fixture.invalid", map[string]string{}); err == nil {
		t.Fatal("blocked upload accepted")
	}
	if transport.sends != 0 {
		t.Fatal("blocked upload reached transport")
	}
	if err := p.relayGate.enable(); err != nil {
		t.Fatal(err)
	}
	if err := p.postJSON(client, "https://fixture.invalid", map[string]string{}); err != nil {
		t.Fatal(err)
	}
	if transport.sends != 1 {
		t.Fatal("new generation did not send")
	}
}

func TestCloudSocketRejectsBeforeDialWhenPureLocal(t *testing.T) {
	p := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	a := &agent{push: p}
	if err := p.relayGate.disableAndDrain(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := a.dialRelayWebSocket(context.Background(), "not-a-socket-url", "", p.relayGate.generation()); err == nil || err.Error() != "pure_local_relay_disabled" {
		t.Fatalf("must reject before resolving or dialing: %v", err)
	}
	if err := p.relayGate.enable(); err != nil {
		t.Fatal(err)
	}
	if _, err := a.dialRelayWebSocket(context.Background(), "not-a-socket-url", "", p.relayGate.generation()); err == nil {
		t.Fatal("invalid URL accepted")
	}
	if err := p.relayGate.disableAndDrain(context.Background()); err != nil {
		t.Fatal("failed attempt leaked", err)
	}
}
