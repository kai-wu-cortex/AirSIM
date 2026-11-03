package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"regexp"
)

type localModeCommand struct {
	Version          int    `json:"version"`
	AgentID          string `json:"agent_id"`
	OperationID      string `json:"operation_id"`
	Enabled          bool   `json:"enabled"`
	ExpectedRevision uint64 `json:"expected_revision"`
	OwnerPublicKey   string `json:"owner_public_key"`
	Signature        string `json:"signature"`
}

var localModeAgentPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
var localModeOperationPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (c localModeCommand) canonical() []byte {
	enabled := 0
	if c.Enabled {
		enabled = 1
	}
	return []byte(fmt.Sprintf("airsim-pure-local-v1\n%s\n%s\n%d\n%d", c.AgentID, c.OperationID, enabled, c.ExpectedRevision))
}

func verifyLocalModeCommand(c localModeCommand, agentID string) error {
	if c.Version != 1 || c.AgentID != agentID || !localModeAgentPattern.MatchString(c.AgentID) ||
		!localModeOperationPattern.MatchString(c.OperationID) || c.ExpectedRevision > math.MaxInt64 ||
		len(c.OwnerPublicKey) != 44 || len(c.Signature) != 88 {
		return errors.New("invalid_command")
	}
	key, err := base64.StdEncoding.Strict().DecodeString(c.OwnerPublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize {
		return errors.New("invalid_signature")
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(c.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize || !ed25519.Verify(key, c.canonical(), signature) {
		return errors.New("invalid_signature")
	}
	return nil
}

func (c localModeCommand) ownerFingerprint() string {
	key, _ := base64.StdEncoding.DecodeString(c.OwnerPublicKey)
	digest := sha256.Sum256(key)
	return hex.EncodeToString(digest[:])
}
