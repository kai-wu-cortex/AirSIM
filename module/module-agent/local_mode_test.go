package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
)

func signedLocalModeCommand(t *testing.T, agent, operation string, enabled bool, revision uint64, key ed25519.PrivateKey) localModeCommand {
	t.Helper()
	command := localModeCommand{Version: 1, AgentID: agent, OperationID: operation, Enabled: enabled,
		ExpectedRevision: revision, OwnerPublicKey: base64.StdEncoding.EncodeToString(key.Public().(ed25519.PublicKey))}
	command.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(key, command.canonical()))
	return command
}

func TestAVFLocalModeRequiresAndroidAuthenticationAndPersistsBeforeAck(t *testing.T) {
	_, privateKey, _ := ed25519.GenerateKey(rand.Reader)
	command := signedLocalModeCommand(t, "android-fixture", "00000000-0000-4000-8000-000000000001", true, 0, privateKey)
	body, _ := json.Marshal(command)
	path := filepath.Join(t.TempDir(), "push.json")
	a := &agent{push: newPushManager(path), android: newAndroidControl("fixture-control-token")}
	a.localModePath = path + ".local-mode"

	request := httptest.NewRequest(http.MethodPost, "/api/android/local-mode", bytes.NewReader(body))
	request.Header.Set("X-AirSIM-Local-Nonce", "fixture-nonce")
	response := httptest.NewRecorder()
	a.localMode(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status=%d", response.Code)
	}

	request = httptest.NewRequest(http.MethodPost, "/api/android/local-mode", bytes.NewReader(body))
	request.Header.Set("Authorization", "Bearer fixture-control-token")
	request.Header.Set("X-AirSIM-Local-Nonce", "fixture-nonce")
	response = httptest.NewRecorder()
	a.localMode(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
	var status localModeStatus
	if json.Unmarshal(response.Body.Bytes(), &status) != nil || !status.Enabled || !status.Drained || !status.AVFConfirmed || status.Revision != 1 {
		t.Fatalf("bad status: %#v", status)
	}
	restored, err := (localModeStore{path: a.localModePath}).read()
	if err != nil || !restored.Blocked || !restored.Enabled {
		t.Fatalf("restriction not durable: %#v %v", restored, err)
	}
	if a.push.relayGate.current(a.push.relayGate.generation()) {
		t.Fatal("Relay open after ACK")
	}
}

func TestAVFLocalModeRejectsRevisionOwnerAndRestoresOnlyAfterDurableExit(t *testing.T) {
	_, owner, _ := ed25519.GenerateKey(rand.Reader)
	_, stranger, _ := ed25519.GenerateKey(rand.Reader)
	path := filepath.Join(t.TempDir(), "push.json")
	a := &agent{push: newPushManager(path), android: newAndroidControl("fixture-control-token"), localModePath: path + ".local-mode"}
	apply := func(command localModeCommand) *httptest.ResponseRecorder {
		body, _ := json.Marshal(command)
		request := httptest.NewRequest(http.MethodPost, "/api/android/local-mode", bytes.NewReader(body))
		request.Header.Set("Authorization", "Bearer fixture-control-token")
		request.Header.Set("X-AirSIM-Local-Nonce", "fixture-nonce")
		response := httptest.NewRecorder()
		a.localMode(response, request)
		return response
	}
	if got := apply(signedLocalModeCommand(t, "android-fixture", "00000000-0000-4000-8000-000000000001", true, 0, owner)); got.Code != 200 {
		t.Fatal(got.Body.String())
	}
	if got := apply(signedLocalModeCommand(t, "android-fixture", "00000000-0000-4000-8000-000000000002", false, 1, stranger)); got.Code != 409 {
		t.Fatalf("owner status=%d", got.Code)
	}
	if got := apply(signedLocalModeCommand(t, "android-fixture", "00000000-0000-4000-8000-000000000003", false, 0, owner)); got.Code != 409 {
		t.Fatalf("revision status=%d", got.Code)
	}
	if got := apply(signedLocalModeCommand(t, "android-fixture", "00000000-0000-4000-8000-000000000004", false, 1, owner)); got.Code != 200 {
		t.Fatal(got.Body.String())
	}
	record, err := (localModeStore{path: a.localModePath}).read()
	if err != nil || record.Blocked || record.Enabled {
		t.Fatalf("exit not committed: %#v %v", record, err)
	}
	if !a.push.relayGate.current(a.push.relayGate.generation()) {
		t.Fatal("Relay not restored")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_ = ctx
}
