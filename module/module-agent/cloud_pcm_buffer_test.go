package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestSpeechBufferPreservesSpeechAcrossTwoHundredMillisecondNetworkGap(t *testing.T) {
	var b cloudPCMSpeechBuffer
	start := time.Unix(1800000000, 0)
	// Prebuffer 200ms without changing a single sample.
	for i := 0; i < 10; i++ {
		b.enqueue(bytes.Repeat([]byte{byte(i)}, 320), start.Add(time.Duration(i)*20*time.Millisecond))
		if i < 9 && b.pop() != nil {
			t.Fatal("played before initial reserve ready")
		}
	}
	for i := 0; i < 10; i++ {
		if !bytes.Equal(b.pop(), bytes.Repeat([]byte{byte(i)}, 320)) {
			t.Fatalf("speech frame %d lost or changed", i)
		}
	}
	if b.dropped != 0 {
		t.Fatal("short gap dropped speech")
	}
	if b.pop() != nil || b.target != 15 {
		t.Fatal("underrun must rebuffer at 300ms")
	}
}

func TestSpeechBufferBoundsLongBacklogAndRebuffer(t *testing.T) {
	var b cloudPCMSpeechBuffer
	start := time.Unix(1800000000, 0)
	for i := 0; i < 75; i++ {
		b.enqueue(bytes.Repeat([]byte{byte(i)}, 320), start.Add(time.Duration(i)*20*time.Millisecond))
	}
	if len(b.frames) != 50 || b.dropped != 25 {
		t.Fatalf("queue=%d drops=%d", len(b.frames), b.dropped)
	}
	for i := 25; i < 75; i++ {
		if b.pop()[0] != byte(i) {
			t.Fatal("speech ordering broken")
		}
	}
	for attempt := 0; attempt < 10; attempt++ {
		b.pop()
		for i := 0; i < b.target; i++ {
			b.enqueue(make([]byte, 320), start)
		}
		for b.pop() != nil {
		}
	}
	if b.target != 30 {
		t.Fatalf("target=%d", b.target)
	}
}

func TestCloudBridgePacesBurstWithoutBlockingControlReader(t *testing.T) {
	writer, reader := net.Pipe()
	defer reader.Close()
	bridge := &cloudPCMBridge{}
	bridge.set(writer)
	defer bridge.close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go bridge.playUplink(ctx)
	// More than the startup reserve arrives immediately; write must enqueue,
	// even though the local PCM reader has not begun reading yet.
	for i := 0; i < 30; i++ {
		if err := bridge.write(encodeCloudPCMFrame(bytes.Repeat([]byte{byte(i)}, 320), uint32(i), uint64(i*20))); err != nil {
			t.Fatal(err)
		}
	}
	_ = reader.SetReadDeadline(time.Now().Add(2 * time.Second))
	first := time.Now()
	for i := 0; i < 5; i++ {
		frame := make([]byte, 320)
		if _, err := io.ReadFull(reader, frame); err != nil {
			t.Fatal(err)
		}
		if frame[0] != byte(i) {
			t.Fatalf("frame %d got %d", i, frame[0])
		}
	}
	if time.Since(first) < 60*time.Millisecond {
		t.Fatal("burst was dumped without 20ms pacing")
	}
}
