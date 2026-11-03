package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

// relayEgress tracks an entire operation, not merely whether a socket was created.
type relayEgress struct {
	mu      sync.Mutex
	blocked bool
	epoch   uint64
	next    uint64
	active  map[uint64]context.CancelFunc
	changed chan struct{}
}

func newRelayEgress(blocked bool) *relayEgress {
	return &relayEgress{blocked: blocked, active: make(map[uint64]context.CancelFunc), changed: make(chan struct{})}
}
func (g *relayEgress) generation() uint64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.epoch
}
func (g *relayEgress) current(epoch uint64) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return !g.blocked && epoch == g.epoch
}
func (g *relayEgress) acquire(parent context.Context, epoch uint64) (context.Context, func(), error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.blocked || epoch != g.epoch {
		return nil, nil, errors.New("pure_local_relay_disabled")
	}
	ctx, cancel := context.WithCancel(parent)
	g.next++
	id := g.next
	g.active[id] = cancel
	var once sync.Once
	return ctx, func() {
		once.Do(func() {
			cancel()
			g.mu.Lock()
			defer g.mu.Unlock()
			delete(g.active, id)
			close(g.changed)
			g.changed = make(chan struct{})
		})
	}, nil
}
func (g *relayEgress) disableAndDrain(ctx context.Context) error {
	g.mu.Lock()
	if !g.blocked {
		g.blocked = true
		g.epoch++
	}
	cancellations := make([]context.CancelFunc, 0, len(g.active))
	for _, cancel := range g.active {
		cancellations = append(cancellations, cancel)
	}
	g.mu.Unlock()
	for _, cancel := range cancellations {
		cancel()
	}
	for {
		g.mu.Lock()
		count := len(g.active)
		changed := g.changed
		g.mu.Unlock()
		if count == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-changed:
		}
	}
}
func (g *relayEgress) enable() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.active) != 0 {
		return errors.New("relay_still_draining")
	}
	if g.blocked {
		g.epoch++
		g.blocked = false
	}
	return nil
}

// Admit before scheduling, and keep the lease through backoff and response handling.
// Restore cannot reopen egress until cancelled jobs have actually returned.
func (a *agent) scheduleRelayJob(work func(context.Context)) {
	if a.push == nil || a.push.relayGate == nil {
		return
	}
	ctx, release, err := a.push.relayGate.acquire(context.Background(), a.push.relayGate.generation())
	if err != nil {
		return
	}
	go func() {
		defer release()
		if ctx.Err() == nil {
			work(ctx)
		}
	}()
}

func waitRelayRetry(ctx context.Context, delay time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return ctx.Err() == nil
	}
}

func (a *agent) dialRelayWebSocket(ctx context.Context, endpoint, token string, epoch uint64) (*cloudWebSocket, error) {
	if a.push == nil || a.push.relayGate == nil {
		return nil, errors.New("relay_policy_unavailable")
	}
	operation, release, err := a.push.relayGate.acquire(ctx, epoch)
	if err != nil {
		return nil, err
	}
	socket, err := dialCloudWebSocketAuthorized(operation, endpoint, token)
	if err != nil {
		release()
		return nil, err
	}
	stop := context.AfterFunc(operation, func() { _ = socket.conn.Close() })
	socket.releaseRelay = func() { stop(); release() }
	if !a.push.relayGate.current(epoch) {
		_ = socket.Close()
		return nil, errors.New("stale_relay_operation")
	}
	return socket, nil
}
