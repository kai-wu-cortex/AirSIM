package main

import (
	"bytes"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	debugMaxEvents      = 2000
	debugMaxPayload     = 32 * 1024
	debugMaxStoredBytes = 2 * 1024 * 1024
)

type debugEvent struct {
	Sequence  uint64            `json:"sequence"`
	Timestamp time.Time         `json:"timestamp"`
	Category  string            `json:"category"`
	Direction string            `json:"direction,omitempty"`
	Summary   string            `json:"summary"`
	Payload   string            `json:"payload,omitempty"`
	Fields    map[string]string `json:"fields,omitempty"`
}

type debugLog struct {
	mu          sync.RWMutex
	next        uint64
	storedBytes int
	events      []debugEvent
}

func (d *debugLog) add(category, direction, summary, payload string, fields map[string]string) {
	if len(payload) > debugMaxPayload {
		payload = payload[:debugMaxPayload] + "\n...[truncated]"
	}
	eventSize := len(category) + len(direction) + len(summary) + len(payload)
	for key, value := range fields {
		eventSize += len(key) + len(value)
	}
	d.mu.Lock()
	d.next++
	event := debugEvent{
		Sequence: d.next, Timestamp: time.Now().UTC(), Category: category,
		Direction: direction, Summary: summary, Payload: payload, Fields: fields,
	}
	d.events = append(d.events, event)
	d.storedBytes += eventSize
	for len(d.events) > debugMaxEvents || d.storedBytes > debugMaxStoredBytes {
		removed := d.events[0]
		d.storedBytes -= debugEventSize(removed)
		d.events = d.events[1:]
	}
	d.mu.Unlock()
}

func debugEventSize(event debugEvent) int {
	size := len(event.Category) + len(event.Direction) + len(event.Summary) + len(event.Payload)
	for key, value := range event.Fields {
		size += len(key) + len(value)
	}
	return size
}

func (d *debugLog) snapshot(after uint64, limit int) ([]debugEvent, uint64, int) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	if limit <= 0 || limit > debugMaxEvents {
		limit = debugMaxEvents
	}
	start := 0
	for start < len(d.events) && d.events[start].Sequence <= after {
		start++
	}
	if remaining := len(d.events) - start; remaining > limit {
		start = len(d.events) - limit
	}
	result := append([]debugEvent(nil), d.events[start:]...)
	return result, d.next, d.storedBytes
}

func (d *debugLog) clear() {
	d.mu.Lock()
	d.events = nil
	d.storedBytes = 0
	d.mu.Unlock()
}

type cappedCapture struct {
	buffer bytes.Buffer
	total  int64
}

func (c *cappedCapture) Write(payload []byte) (int, error) {
	c.total += int64(len(payload))
	remaining := debugMaxPayload - c.buffer.Len()
	if remaining > 0 {
		if len(payload) < remaining {
			remaining = len(payload)
		}
		_, _ = c.buffer.Write(payload[:remaining])
	}
	return len(payload), nil
}

func (c *cappedCapture) text() string {
	result := c.buffer.String()
	if c.total > int64(c.buffer.Len()) {
		result += "\n...[truncated]"
	}
	return result
}

type teeReadCloser struct {
	io.Reader
	io.Closer
}

type debugResponseWriter struct {
	http.ResponseWriter
	status  int
	capture cappedCapture
}

func (w *debugResponseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *debugResponseWriter) Write(payload []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	_, _ = w.capture.Write(payload)
	return w.ResponseWriter.Write(payload)
}

func (a *agent) debugStatus(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodGet) {
		return
	}
	limit, _ := strconv.Atoi(request.URL.Query().Get("limit"))
	after, _ := strconv.ParseUint(request.URL.Query().Get("after"), 10, 64)
	events, latest, storedBytes := a.debug.snapshot(after, limit)
	atHealth := a.at.healthSnapshot()

	a.mu.RLock()
	modem := a.modem
	var active *callRecord
	if a.calls.Active != nil {
		copy := *a.calls.Active
		active = &copy
	}
	callState := map[string]any{
		"active": active, "history_count": len(a.calls.History),
		"event_driven": a.calls.EventDriven, "last_error": a.calls.LastPollError,
	}
	smsState := map[string]any{"count": len(a.messages), "last_error": a.smsError}
	a.mu.RUnlock()

	rx, tx, trafficError := readInterfaceCounters("ecm0")
	traffic := map[string]any{"interface": "ecm0", "rx_bytes": rx, "tx_bytes": tx}
	if trafficError != nil {
		traffic["error"] = trafficError.Error()
	}
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	usbFault := a.captureUSBFaultSnapshot("current", "debug-api", "")

	writeJSON(response, http.StatusOK, map[string]any{
		"debug": map[string]any{
			"latest_sequence": latest, "returned_events": len(events),
			"stored_bytes": storedBytes, "max_events": debugMaxEvents,
			"max_stored_bytes": debugMaxStoredBytes,
		},
		"agent": map[string]any{
			"version": agentVersion, "uptime_seconds": int(time.Since(a.started).Seconds()),
			"goroutines": runtime.NumGoroutine(), "heap_bytes": memory.HeapAlloc,
			"memory_limit_bytes": agentMemoryLimitBytes, "gc_percent": agentGCPercent,
		},
		"at": map[string]any{
			"device": a.at.path, "last_success_at": atHealth.LastSuccess,
			"consecutive_failures": atHealth.ConsecutiveFailures, "reopen_count": atHealth.ReopenCount,
		},
		"usb": map[string]string{
			"functions":     readDebugFile(usbGadgetPath + "/functions"),
			"enabled":       readDebugFile(usbGadgetPath + "/enable"),
			"ecm_carrier":   readDebugFile("/sys/class/net/ecm0/carrier"),
			"ecm_operstate": readDebugFile("/sys/class/net/ecm0/operstate"),
		},
		"usb_fault": usbFault,
		"traffic":   traffic, "modem": modem, "calls": callState, "sms": smsState,
		"voice": a.currentVoiceStatus(), "events": events,
	})
}

func (a *agent) debugClear(response http.ResponseWriter, request *http.Request) {
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	a.debug.clear()
	a.debug.add("system", "", "debug log cleared", "", nil)
	writeJSON(response, http.StatusOK, map[string]bool{"cleared": true})
}

func readDebugFile(path string) string {
	value, err := os.ReadFile(path)
	if err != nil {
		return "unavailable: " + err.Error()
	}
	return strings.TrimSpace(string(value))
}
