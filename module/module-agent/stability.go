package main

import (
	"context"
	"log"
	"net/http"
	"runtime"
	runtimedebug "runtime/debug"
	"strings"
	"sync"
	"time"
)

const (
	agentMemoryLimitBytes  = 20 << 20
	agentGCPercent         = 50
	defaultNormalRequests  = 4
	defaultControlRequests = 4
	defaultLongPolls       = 2
)

type requestClass uint8

const (
	requestClassNormal requestClass = iota
	requestClassControl
	requestClassLongPoll
	requestClassAndroidPoll
)

type requestAdmission struct {
	normal      chan struct{}
	control     chan struct{}
	longPoll    chan struct{}
	androidPoll chan struct{}
}

func newRequestAdmission(normal, control, longPoll int) *requestAdmission {
	return &requestAdmission{
		normal: make(chan struct{}, normal), control: make(chan struct{}, control),
		longPoll:    make(chan struct{}, longPoll),
		androidPoll: make(chan struct{}, 1),
	}
}

func classifyRequest(path string) requestClass {
	switch path {
	case "/api/android/commands/next":
		return requestClassAndroidPoll
	case "/api/events", "/api/calls/events":
		return requestClassLongPoll
	case "/api/health", "/api/android/calls/event", "/api/android/commands/result":
		return requestClassControl
	}
	if strings.HasPrefix(path, "/api/calls/dial") ||
		strings.HasPrefix(path, "/api/calls/answer") ||
		strings.HasPrefix(path, "/api/calls/reject") ||
		strings.HasPrefix(path, "/api/calls/hangup") ||
		strings.HasPrefix(path, "/api/calls/dtmf") ||
		strings.HasPrefix(path, "/api/calls/audio/") {
		return requestClassControl
	}
	return requestClassNormal
}

func (a *requestAdmission) acquire(ctx context.Context, path string) (func(), bool) {
	var semaphore chan struct{}
	switch classifyRequest(path) {
	case requestClassControl:
		semaphore = a.control
	case requestClassLongPoll:
		semaphore = a.longPoll
	case requestClassAndroidPoll:
		semaphore = a.androidPoll
	default:
		semaphore = a.normal
	}
	select {
	case semaphore <- struct{}{}:
		return func() { <-semaphore }, true
	case <-ctx.Done():
		return func() {}, false
	default:
		return func() {}, false
	}
}

func rejectBusy(response http.ResponseWriter) {
	response.Header().Set("Retry-After", "1")
	writeError(response, http.StatusServiceUnavailable, "Agent 正在保护通话控制，请稍后重试")
}

// operationFlight 让同一控制操作的并发请求等待同一结果，避免重复发送 AT 命令。
type operationFlight struct {
	mu   sync.Mutex
	call *operationCall
}

type operationCall struct {
	done chan struct{}
	err  error
}

func (f *operationFlight) Do(operation func() error) error {
	f.mu.Lock()
	if call := f.call; call != nil {
		f.mu.Unlock()
		<-call.done
		return call.err
	}
	call := &operationCall{done: make(chan struct{})}
	f.call = call
	f.mu.Unlock()

	call.err = operation()
	f.mu.Lock()
	f.call = nil
	close(call.done)
	f.mu.Unlock()
	return call.err
}

func configureRuntimeStability() {
	runtimedebug.SetMemoryLimit(agentMemoryLimitBytes)
	runtimedebug.SetGCPercent(agentGCPercent)
}

func startRuntimeMonitor(logger *log.Logger) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		var memory runtime.MemStats
		runtime.ReadMemStats(&memory)
		goroutines := runtime.NumGoroutine()
		if memory.HeapAlloc >= 16<<20 || goroutines >= 256 {
			logger.Printf("运行压力告警 goroutines=%d heap=%d limit=%d，主动回收", goroutines, memory.HeapAlloc, agentMemoryLimitBytes)
			runtime.GC()
		}
	}
}
