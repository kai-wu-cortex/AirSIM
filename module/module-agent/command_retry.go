package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func validCommandAgentID(id string) bool {
	if len(id) == 0 || len(id) > 128 || strings.TrimSpace(id) != id || !utf8.ValidString(id) {
		return false
	}
	for _, r := range id {
		if r < 32 || r == 127 {
			return false
		}
	}
	return true
}

type cloudPeerClose struct{ Code int }

func (e *cloudPeerClose) Error() string {
	return fmt.Sprintf("WebSocket close %d (%s)", e.Code, e.Category())
}
func (e *cloudPeerClose) Category() string {
	switch e.Code {
	case 4001:
		return "replaced"
	case 1000, 1001, 1005:
		return "normal"
	case 1002, 1003, 1007, 1008, 1009:
		return "protocol"
	default:
		return "remote_error"
	}
}
func decodeCloudPeerClose(payload []byte) error {
	if len(payload) == 0 {
		return &cloudPeerClose{1005}
	}
	if len(payload) < 2 || len(payload) > 125 {
		return errors.New("invalid close length")
	}
	code := int(binary.BigEndian.Uint16(payload))
	if !((code >= 1000 && code <= 1014 && code != 1004 && code != 1005 && code != 1006) || (code >= 3000 && code <= 4999)) || !utf8.Valid(payload[2:]) {
		return errors.New("invalid close payload")
	}
	return &cloudPeerClose{code}
}

type relayCommandHTTPError struct {
	Status     int
	RetryAfter time.Duration
}

func (e *relayCommandHTTPError) Error() string { return fmt.Sprintf("Relay HTTP %d", e.Status) }
func commandRetryAfter(value string, now time.Time) time.Duration {
	if seconds, err := strconv.ParseUint(value, 10, 64); err == nil {
		if seconds > uint64((1<<63-1)/int64(time.Second)) {
			return time.Duration(1<<63 - 1)
		}
		return time.Duration(seconds) * time.Second
	}
	if at, err := http.ParseTime(value); err == nil && at.After(now) {
		return at.Sub(now)
	}
	return 0
}
func cloudCommandErrorDelay(failures int, err error) time.Duration {
	if failures < 1 {
		failures = 1
	}
	if failures > 6 {
		failures = 6
	}
	delay := cloudCommandReconnectDelay(failures)
	var close *cloudPeerClose
	var httpErr *relayCommandHTTPError
	if errors.As(err, &close) && close.Code == 4001 {
		delay = time.Minute << (failures - 1)
	}
	if errors.As(err, &httpErr) && (httpErr.Status == 429 || httpErr.Status >= 500) {
		delay = 15 * time.Second << (failures - 1)
	}
	if delay > 5*time.Minute {
		delay = 5 * time.Minute
	}
	if httpErr != nil && httpErr.RetryAfter > delay {
		delay = httpErr.RetryAfter
	}
	return delay
}

func (p *pushManager) beginCommandPull(now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.commandConnected || now.Before(p.commandRetryAt) || (!p.lastCommandPull.IsZero() && now.Sub(p.lastCommandPull) < 15*time.Second) {
		return false
	}
	p.lastCommandPull = now
	return true
}
func (p *pushManager) commandFailed(failures int, err error) time.Duration {
	return p.commandFailedFor(nil, failures, err)
}

func (p *pushManager) commandFailedFor(origin *pushRegistration, failures int, err error) time.Duration {
	delay := cloudCommandErrorDelay(failures, err)
	// Never overflow or shorten an explicit Retry-After.
	if delay < time.Duration(1<<62) {
		delay += time.Duration(float64(delay) * .25 * rand.Float64())
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if origin != nil && (!p.cloudEnabledLocked() || !sameCommandRegistration(p.config, *origin)) {
		return 0
	}
	until := time.Now().Add(delay)
	if until.After(p.commandRetryAt) {
		p.commandRetryAt = until
	}
	return time.Until(p.commandRetryAt)
}
