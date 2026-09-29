package main

import (
	"math"
	"time"
)

// The receiver, not the sender, absorbs network bursts. A single 20 ms
// playout clock preserves speech cadence instead of dumping a burst into PCM.
// Access is serialized by cloudPCMBridge.mu.
type cloudPCMSpeechBuffer struct {
	frames      [][]byte
	target      int
	primed      bool
	lastArrival time.Time
	jitter      float64
	dropped     uint64
	underruns   uint64
}

func (b *cloudPCMSpeechBuffer) enqueue(frame []byte, at time.Time) {
	if b.target == 0 {
		b.target = 10
	}
	if !b.lastArrival.IsZero() {
		variation := math.Abs(at.Sub(b.lastArrival).Seconds() - 0.02)
		b.jitter += (variation - b.jitter) / 16
		desired := 10 + int(4*b.jitter/0.02)
		if desired > 30 {
			desired = 30
		}
		if desired > b.target {
			b.target = desired
		}
	}
	b.lastArrival = at
	b.frames = append(b.frames, append([]byte(nil), frame...))
	if len(b.frames) > 50 {
		b.frames[0] = nil
		b.frames = b.frames[1:]
		b.dropped++
	}
}

func (b *cloudPCMSpeechBuffer) pop() []byte {
	if !b.primed {
		if len(b.frames) < b.target || b.target == 0 {
			return nil
		}
		b.primed = true
	}
	if len(b.frames) == 0 {
		b.primed = false
		b.underruns++
		b.target += 5
		if b.target > 30 {
			b.target = 30
		}
		return nil
	}
	frame := b.frames[0]
	b.frames[0] = nil
	b.frames = b.frames[1:]
	return frame
}
