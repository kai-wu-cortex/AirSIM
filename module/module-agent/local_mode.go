package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type localModeStatus struct {
	Version          int    `json:"version"`
	AgentID          string `json:"agent_id"`
	Enabled          bool   `json:"enabled"`
	Revision         uint64 `json:"revision"`
	LastOperationID  string `json:"last_operation_id"`
	OwnerFingerprint string `json:"owner_fingerprint"`
	Source           string `json:"source"`
	Drained          bool   `json:"drained"`
	AVFRequired      bool   `json:"avf_required"`
	AVFConfirmed     bool   `json:"avf_confirmed"`
	StatusProof      string `json:"status_proof,omitempty"`
}

func localStatusFromRecord(record localModeRecord, drained bool) localModeStatus {
	return localModeStatus{Version: 1, AgentID: record.AgentID, Enabled: record.Enabled,
		Revision: record.Revision, LastOperationID: record.OperationID, OwnerFingerprint: record.Owner,
		Source: record.Source, Drained: drained, AVFRequired: true, AVFConfirmed: drained}
}

func (a *agent) signLocalStatus(status *localModeStatus, nonce string) {
	if a.android == nil || a.android.token == "" {
		return
	}
	bit := func(value bool) int {
		if value {
			return 1
		}
		return 0
	}
	encoded := []byte(fmt.Sprintf("airsim-pure-local-status-v1\n%s\n1\n%s\n%d\n%d\n%s\n%s\n%s\n%d\n%d\n%d",
		nonce, status.AgentID, bit(status.Enabled), status.Revision, status.LastOperationID,
		status.OwnerFingerprint, status.Source, bit(status.Drained), bit(status.AVFRequired), bit(status.AVFConfirmed)))
	mac := hmac.New(sha256.New, []byte(a.android.token))
	_, _ = mac.Write(encoded)
	status.StatusProof = base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func (a *agent) localMode(response http.ResponseWriter, request *http.Request) {
	if a.android == nil || !a.android.configured() {
		writeError(response, http.StatusServiceUnavailable, "Android control unavailable")
		return
	}
	if !a.android.authorized(request.Header.Get("Authorization")) {
		writeError(response, http.StatusUnauthorized, "Android control authentication failed")
		return
	}
	store := localModeStore{path: a.localModePath}
	nonce := request.Header.Get("X-AirSIM-Local-Nonce")
	if nonce == "" || len(nonce) > 256 {
		writeError(response, http.StatusBadRequest, "invalid_nonce")
		return
	}
	record, readErr := store.read()
	if readErr != nil {
		writeError(response, http.StatusServiceUnavailable, readErr.Error())
		return
	}
	if request.Method == http.MethodGet {
		status := localStatusFromRecord(record, !record.Blocked || !a.push.relayGate.current(a.push.relayGate.generation()))
		a.signLocalStatus(&status, nonce)
		writeJSON(response, http.StatusOK, status)
		return
	}
	if request.Method != http.MethodPost {
		writeError(response, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	var command localModeCommand
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, 32<<10))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&command) != nil || verifyLocalModeCommand(command, command.AgentID) != nil {
		writeError(response, http.StatusBadRequest, "invalid_command")
		return
	}
	if record.Revision > 0 && command.OperationID == record.OperationID {
		status := localStatusFromRecord(record, record.Blocked && !a.push.relayGate.current(a.push.relayGate.generation()))
		a.signLocalStatus(&status, nonce)
		writeJSON(response, http.StatusOK, status)
		return
	}
	if command.ExpectedRevision != record.Revision {
		writeError(response, http.StatusConflict, "revision_conflict")
		return
	}
	owner := command.ownerFingerprint()
	if record.Revision > 0 && owner != record.Owner {
		writeError(response, http.StatusConflict, "owner_mismatch")
		return
	}
	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	if callActive {
		writeError(response, http.StatusConflict, "active_call")
		return
	}
	if command.Enabled == record.Enabled && record.Revision > 0 {
		writeError(response, http.StatusConflict, "state_conflict")
		return
	}

	if command.Enabled {
		a.push.mu.Lock()
		prior := a.push.config
		a.push.mu.Unlock()
		next := localModeRecord{Version: 1, AgentID: command.AgentID, Enabled: true, Blocked: true,
			Revision: record.Revision + 1, OperationID: command.OperationID, Owner: owner, Source: "remote", Prior: &prior}
		if err := store.commit(next); err != nil {
			writeError(response, http.StatusServiceUnavailable, "persistence_failed")
			return
		}
		ctx, cancel := context.WithTimeout(request.Context(), 5*time.Second)
		defer cancel()
		if err := a.push.relayGate.disableAndDrain(ctx); err != nil {
			writeError(response, http.StatusServiceUnavailable, "draining")
			return
		}
		status := localStatusFromRecord(next, true)
		a.signLocalStatus(&status, nonce)
		writeJSON(response, http.StatusOK, status)
		return
	}
	if record.Revision == 0 || !record.Blocked || record.Prior == nil {
		writeError(response, http.StatusConflict, "not_enabled")
		return
	}
	pending := record
	pending.Enabled = false
	pending.Revision++
	pending.OperationID = command.OperationID
	if err := store.commit(pending); err != nil {
		writeError(response, http.StatusServiceUnavailable, "persistence_failed")
		return
	}
	ctx, cancel := context.WithTimeout(request.Context(), 5*time.Second)
	defer cancel()
	if err := a.push.relayGate.disableAndDrain(ctx); err != nil {
		writeError(response, http.StatusServiceUnavailable, "draining")
		return
	}
	if err := a.push.restoreSnapshot(*record.Prior); err != nil {
		writeError(response, http.StatusServiceUnavailable, "restore_failed")
		return
	}
	completed := pending
	completed.Blocked = false
	completed.Prior = nil
	if err := store.commit(completed); err != nil {
		writeError(response, http.StatusServiceUnavailable, "persistence_failed")
		return
	}
	if err := a.push.relayGate.enable(); err != nil {
		writeError(response, http.StatusServiceUnavailable, "draining")
		return
	}
	status := localStatusFromRecord(completed, true)
	a.signLocalStatus(&status, nonce)
	writeJSON(response, http.StatusOK, status)
}

func (p *pushManager) restoreSnapshot(snapshot pushRegistration) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	if err := writePushConfigAtomically(p.configPath, data); err != nil {
		return err
	}
	snapshot.commandEpoch = p.config.commandEpoch + 1
	p.config = snapshot
	if p.commandSocket != nil {
		_ = p.commandSocket.Close()
		p.commandSocket = nil
	}
	return nil
}
