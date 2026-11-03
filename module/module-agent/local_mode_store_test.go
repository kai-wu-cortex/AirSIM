package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalModePersistsRestrictionBeforeAgentRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	store := localModeStore{path: path + ".local-mode"}
	record := localModeRecord{Version: 1, AgentID: "fixture-agent", Enabled: true, Blocked: true,
		Revision: 1, OperationID: "00000000-0000-4000-8000-000000000001",
		Owner: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Source: "remote",
		Prior: &pushRegistration{RelayURL: "https://fixture.invalid"}}
	if err := store.commit(record); err != nil {
		t.Fatal(err)
	}
	restored, err := store.read()
	if err != nil || !restored.Blocked || restored.Prior.RelayURL != "https://fixture.invalid" {
		t.Fatalf("snapshot lost: %v", err)
	}
	p := newPushManager(path)
	if p.relayGate.current(p.relayGate.generation()) {
		t.Fatal("restart reopened Relay")
	}
	// An exit intent still blocks until the complete restore transaction is durable.
	record.Enabled = false
	record.Revision = 2
	if err := store.commit(record); err != nil {
		t.Fatal(err)
	}
	if p = newPushManager(path); p.relayGate.current(p.relayGate.generation()) {
		t.Fatal("pending exit reopened Relay")
	}
	record.Blocked = false
	record.Prior = nil
	if err := store.commit(record); err != nil {
		t.Fatal(err)
	}
	if p = newPushManager(path); !p.relayGate.current(p.relayGate.generation()) {
		t.Fatal("completed restore not reopened")
	}
}

func TestLocalModeCorruptOrUnreadablePolicyFailsClosed(t *testing.T) {
	for _, value := range []string{"", "{}", "null", `{"version":1,"blocked":false}`, "broken"} {
		t.Run(value, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "push.json")
			if err := os.WriteFile(path+".local-mode", []byte(value), 0600); err != nil {
				t.Fatal(err)
			}
			p := newPushManager(path)
			if p.relayGate.current(p.relayGate.generation()) {
				t.Fatal("corrupt policy reopened Relay")
			}
		})
	}
	path := filepath.Join(t.TempDir(), "push.json")
	if err := os.Mkdir(path+".local-mode", 0700); err != nil {
		t.Fatal(err)
	}
	p := newPushManager(path)
	if p.relayGate.current(p.relayGate.generation()) {
		t.Fatal("unreadable policy reopened Relay")
	}
}
