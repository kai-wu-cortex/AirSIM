package main

import (
	"testing"
	"time"
)

func TestAndroidBatteryFreshnessAndMissingValues(t *testing.T) {
	c := newAndroidControl("test")
	now := time.UnixMilli(1800000000000)
	c.updateBattery(`{"percent":0,"charging":true,"observed_at_ms":1800000000000}`, now)
	if v := c.batterySnapshot(now); v == nil || *v.Percent != 0 || !v.Charging {
		t.Fatal("zero/charging lost")
	}
	if c.batterySnapshot(now.Add(5*time.Minute)) != nil {
		t.Fatal("stale battery leaked")
	}
	for _, raw := range []string{"", `{}`, `{"percent":101,"observed_at_ms":1800000000000}`, `{"percent":50,"observed_at_ms":1800001000000}`} {
		c.updateBattery(raw, now)
		if c.batterySnapshot(now) != nil {
			t.Fatalf("invalid battery accepted: %s", raw)
		}
	}
}
