package main

import (
	"encoding/json"
	"time"
)

// The Android host supplies this on its authenticated command poll. Never use
// Linux guest power/sysfs values as the physical phone's battery percentage.
type androidBatteryReading struct {
	Percent      *int  `json:"percent"`
	Charging     bool  `json:"charging"`
	ObservedAtMS int64 `json:"observed_at_ms"`
}

func (c *androidControl) updateBattery(raw string, now time.Time) {
	var value androidBatteryReading
	valid := len(raw) > 0 && len(raw) <= 256 && json.Unmarshal([]byte(raw), &value) == nil
	valid = valid && value.Percent != nil && *value.Percent >= 0 && *value.Percent <= 100
	age := now.UnixMilli() - value.ObservedAtMS
	valid = valid && value.ObservedAtMS > 0 && age >= -60_000 && age < 300_000
	c.mu.Lock()
	defer c.mu.Unlock()
	c.battery = nil
	if valid {
		c.battery = &value
	}
}

func (c *androidControl) batterySnapshot(now time.Time) *androidBatteryReading {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.battery == nil {
		return nil
	}
	age := now.UnixMilli() - c.battery.ObservedAtMS
	if age < -60_000 || age >= 300_000 {
		return nil
	}
	copy := *c.battery
	return &copy
}
