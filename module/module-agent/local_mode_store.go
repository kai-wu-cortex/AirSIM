package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"regexp"
)

// This independent journal must never fall back to an older, permissive copy.
// Blocked stays true through a pending exit, even though Enabled is already false.
type localModeRecord struct {
	Version     int               `json:"version"`
	AgentID     string            `json:"agent_id"`
	Enabled     bool              `json:"enabled"`
	Blocked     bool              `json:"blocked"`
	Revision    uint64            `json:"revision"`
	OperationID string            `json:"last_operation_id"`
	Owner       string            `json:"owner_fingerprint"`
	Source      string            `json:"source"`
	Prior       *pushRegistration `json:"prior_registration"`
}

type localModeStore struct{ path string }
type localModeEnvelope struct {
	Payload json.RawMessage `json:"payload"`
	SHA256  string          `json:"sha256"`
}

var localModeOwnerPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (r localModeRecord) valid() bool {
	return r.Version == 1 && localModeAgentPattern.MatchString(r.AgentID) &&
		r.Revision > 0 && r.Revision <= math.MaxInt64 && localModeOperationPattern.MatchString(r.OperationID) &&
		localModeOwnerPattern.MatchString(r.Owner) && (r.Source == "remote" || r.Source == "android_local") &&
		(!r.Enabled || r.Blocked) && (r.Blocked == (r.Prior != nil))
}

func (s localModeStore) read() (localModeRecord, error) {
	denied := localModeRecord{Blocked: true}
	file, err := os.Open(s.path)
	if os.IsNotExist(err) {
		return localModeRecord{}, nil
	}
	if err != nil {
		return denied, errors.New("local_mode_policy_unreadable")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 262145))
	if err != nil || len(data) > 262144 {
		return denied, errors.New("local_mode_policy_unreadable")
	}
	var envelope localModeEnvelope
	if json.Unmarshal(data, &envelope) != nil {
		return denied, errors.New("local_mode_policy_corrupt")
	}
	sum := sha256.Sum256(envelope.Payload)
	if envelope.SHA256 != hex.EncodeToString(sum[:]) {
		return denied, errors.New("local_mode_policy_corrupt")
	}
	var record localModeRecord
	decoder := json.NewDecoder(bytes.NewReader(envelope.Payload))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&record) != nil || !record.valid() {
		return denied, errors.New("local_mode_policy_corrupt")
	}
	return record, nil
}

func (s localModeStore) commit(record localModeRecord) error {
	if !record.valid() {
		return errors.New("invalid_local_mode_policy")
	}
	payload, err := json.Marshal(record)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(payload)
	data, err := json.Marshal(localModeEnvelope{Payload: payload, SHA256: hex.EncodeToString(sum[:])})
	if err != nil {
		return err
	}
	if len(data) > 262144 {
		return errors.New("local_mode_policy_too_large")
	}
	return writePushConfigAtomically(s.path, data)
}
