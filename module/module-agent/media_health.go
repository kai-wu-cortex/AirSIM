package main

import (
	"strings"
	"sync"
	"time"
)

const (
	cloudMediaTransportLegacyPCM = "legacy_pcm"
	cloudMediaTransportWebRTC    = "webrtc"
)

func resolveCloudMediaTransport(requested string, supported []string, forceLegacy bool) string {
	if forceLegacy || strings.ToLower(strings.TrimSpace(requested)) != cloudMediaTransportWebRTC {
		return cloudMediaTransportLegacyPCM
	}
	for _, transport := range supported {
		if strings.ToLower(strings.TrimSpace(transport)) == cloudMediaTransportWebRTC {
			return cloudMediaTransportWebRTC
		}
	}
	return cloudMediaTransportLegacyPCM
}

type cloudMediaHealthDecision string

const (
	cloudMediaHealthy                cloudMediaHealthDecision = "healthy"
	cloudMediaRebuildDownlinkStalled cloudMediaHealthDecision = "rebuild_downlink_stalled"
	cloudMediaRebuildDownlinkSilent  cloudMediaHealthDecision = "rebuild_downlink_silent"
	cloudMediaRebuildUplinkStalled   cloudMediaHealthDecision = "rebuild_uplink_stalled"
	cloudMediaRebuildConnectionLost  cloudMediaHealthDecision = "rebuild_connection_lost"
	cloudMediaRebuildExhausted       cloudMediaHealthDecision = "rebuild_exhausted"
)

const (
	cloudMediaStallInterval       = 6 * time.Second
	cloudMediaStartupInterval     = 8 * time.Second
	cloudMediaSilentFrameLimit    = uint64(50)
	cloudMediaAudiblePeakMinimum  = uint64(32)
	cloudMediaMaximumRebuildCount = 3
)

type cloudMediaHealthSnapshot struct {
	CallID                    string    `json:"call_id,omitempty"`
	CallUUID                  string    `json:"call_uuid,omitempty"`
	Generation                uint64    `json:"generation,omitempty"`
	AnswerAcknowledgedAt      time.Time `json:"answer_ack_at,omitempty"`
	ListeningAt               time.Time `json:"pcm_listening_at,omitempty"`
	HandshakeAt               time.Time `json:"pcm_handshake_at,omitempty"`
	FirstDownlinkAt           time.Time `json:"first_downlink_at,omitempty"`
	LastDownlinkAt            time.Time `json:"last_downlink_at,omitempty"`
	LastUplinkAt              time.Time `json:"last_uplink_at,omitempty"`
	DownlinkBytes             uint64    `json:"downlink_bytes"`
	DownlinkFrames            uint64    `json:"downlink_frames"`
	DownlinkPeak              uint64    `json:"downlink_peak"`
	UplinkBytes               uint64    `json:"uplink_bytes"`
	UplinkFrames              uint64    `json:"uplink_frames"`
	UplinkPeak                uint64    `json:"uplink_peak"`
	DroppedFrames             uint64    `json:"dropped_frames"`
	JitterBufferHighWatermark int       `json:"jitter_buffer_high_watermark"`
	RebuildCount              int       `json:"rebuild_count"`
	AudioRoute                string    `json:"audio_route"`
	MediaProtocol             string    `json:"media_protocol,omitempty"`
	UplinkBufferTargetMS      int       `json:"uplink_buffer_target_ms"`
	UplinkBufferFrames        int       `json:"uplink_buffer_frames"`
	UplinkUnderruns           uint64    `json:"uplink_underruns"`
	LastIssue                 string    `json:"last_issue,omitempty"`
}

func (tracker *cloudMediaHealthTracker) markAnswerAcknowledged(at time.Time) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.snapshotValue.AnswerAcknowledgedAt.IsZero() {
		tracker.snapshotValue.AnswerAcknowledgedAt = at
	}
}

func (tracker *cloudMediaHealthTracker) markListening(at time.Time) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.snapshotValue.ListeningAt.IsZero() {
		tracker.snapshotValue.ListeningAt = at
	}
}

type cloudMediaHealthTracker struct {
	mu                      sync.Mutex
	mediaExpected           bool
	windowStartedAt         time.Time
	windowLastDownlinkAt    time.Time
	windowLastUplinkAt      time.Time
	consecutiveSilentFrames uint64
	snapshotValue           cloudMediaHealthSnapshot
}

// The clock starts only after the PCM handshake, never when the phone starts
// ringing. Reconnecting resets the observation window, not the rebuild budget.
func (tracker *cloudMediaHealthTracker) beginMedia(at time.Time) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	tracker.mediaExpected = true
	tracker.windowStartedAt = at
	if tracker.snapshotValue.HandshakeAt.IsZero() {
		tracker.snapshotValue.HandshakeAt = at
	}
	tracker.windowLastDownlinkAt = time.Time{}
	tracker.windowLastUplinkAt = time.Time{}
}

func newCloudMediaHealthTracker(startedAt time.Time, descriptor cloudCallDescriptor) *cloudMediaHealthTracker {
	if startedAt.IsZero() {
		startedAt = time.Now()
	}
	generation := descriptor.Generation
	if generation == 0 && descriptor.CallID != "" {
		generation = 1
	}
	return &cloudMediaHealthTracker{
		windowStartedAt: startedAt,
		snapshotValue: cloudMediaHealthSnapshot{
			CallID: descriptor.CallID, CallUUID: descriptor.CallUUID, Generation: generation,
			AudioRoute: "module_voice_pcm",
		},
	}
}

func (tracker *cloudMediaHealthTracker) observeDownlink(frame []byte, at time.Time, jitterBufferFrames int) {
	if tracker == nil || len(frame) == 0 {
		return
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.snapshotValue.FirstDownlinkAt.IsZero() {
		tracker.snapshotValue.FirstDownlinkAt = at
	}
	tracker.snapshotValue.LastDownlinkAt = at
	tracker.windowLastDownlinkAt = at
	tracker.snapshotValue.DownlinkBytes += uint64(len(frame))
	tracker.snapshotValue.DownlinkFrames += uint64(maxInt(1, len(frame)/cloudPCMFrameBytes))
	peak := cloudPCM16LEPeak(frame)
	if peak > tracker.snapshotValue.DownlinkPeak {
		tracker.snapshotValue.DownlinkPeak = peak
	}
	if jitterBufferFrames > tracker.snapshotValue.JitterBufferHighWatermark {
		tracker.snapshotValue.JitterBufferHighWatermark = jitterBufferFrames
	}
	if peak < cloudMediaAudiblePeakMinimum {
		tracker.consecutiveSilentFrames += uint64(maxInt(1, len(frame)/cloudPCMFrameBytes))
	} else {
		tracker.consecutiveSilentFrames = 0
	}
}

func (tracker *cloudMediaHealthTracker) observeUplink(frame []byte, at time.Time) {
	if tracker == nil || len(frame) == 0 {
		return
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	tracker.windowLastUplinkAt = at
	tracker.snapshotValue.LastUplinkAt = at
	tracker.snapshotValue.UplinkBytes += uint64(len(frame))
	tracker.snapshotValue.UplinkFrames += uint64(maxInt(1, len(frame)/cloudPCMFrameBytes))
	if peak := cloudPCM16LEPeak(frame); peak > tracker.snapshotValue.UplinkPeak {
		tracker.snapshotValue.UplinkPeak = peak
	}
}

func (tracker *cloudMediaHealthTracker) addDroppedFrames(count uint64) {
	if tracker == nil || count == 0 {
		return
	}
	tracker.mu.Lock()
	tracker.snapshotValue.DroppedFrames += count
	tracker.mu.Unlock()
}

func (tracker *cloudMediaHealthTracker) setMediaProtocol(value string) {
	if tracker == nil {
		return
	}
	tracker.mu.Lock()
	tracker.snapshotValue.MediaProtocol = normalizedCloudPCMProtocol(value)
	tracker.mu.Unlock()
}

func (tracker *cloudMediaHealthTracker) observeUplinkBuffer(frames, target int, underruns uint64) {
	if tracker == nil {
		return
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	tracker.snapshotValue.UplinkBufferFrames = frames
	tracker.snapshotValue.UplinkBufferTargetMS = target * 20
	tracker.snapshotValue.UplinkUnderruns = underruns
	if frames > tracker.snapshotValue.JitterBufferHighWatermark {
		tracker.snapshotValue.JitterBufferHighWatermark = frames
	}
}

func (tracker *cloudMediaHealthTracker) evaluate(at time.Time) cloudMediaHealthDecision {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if !tracker.mediaExpected {
		return cloudMediaHealthy
	}
	issue := cloudMediaHealthy
	lastDownlink := tracker.windowLastDownlinkAt
	downlinkTimeout := cloudMediaStallInterval
	if lastDownlink.IsZero() {
		lastDownlink = tracker.windowStartedAt
		downlinkTimeout = cloudMediaStartupInterval
	}
	if at.Sub(lastDownlink) >= downlinkTimeout {
		issue = cloudMediaRebuildDownlinkStalled
	} else {
		lastUplink := tracker.windowLastUplinkAt
		if lastUplink.IsZero() {
			lastUplink = tracker.windowStartedAt
		}
		if tracker.snapshotValue.DownlinkFrames > 0 && at.Sub(lastUplink) >= cloudMediaStallInterval {
			issue = cloudMediaRebuildUplinkStalled
		}
	}
	if issue != cloudMediaHealthy && tracker.snapshotValue.RebuildCount >= cloudMediaMaximumRebuildCount {
		return cloudMediaRebuildExhausted
	}
	return issue
}

func (tracker *cloudMediaHealthTracker) beginRebuild(issue cloudMediaHealthDecision, at time.Time) bool {
	if tracker == nil {
		return false
	}
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.snapshotValue.RebuildCount >= cloudMediaMaximumRebuildCount {
		return false
	}
	tracker.snapshotValue.RebuildCount++
	tracker.snapshotValue.LastIssue = string(issue)
	tracker.windowStartedAt = at
	tracker.windowLastDownlinkAt = time.Time{}
	tracker.windowLastUplinkAt = time.Time{}
	tracker.consecutiveSilentFrames = 0
	return true
}

func (tracker *cloudMediaHealthTracker) snapshot() cloudMediaHealthSnapshot {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	return tracker.snapshotValue
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}
