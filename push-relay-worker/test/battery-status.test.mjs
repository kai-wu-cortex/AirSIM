import test from "node:test";
import assert from "node:assert/strict";
import { batteryStatus } from "../src/battery-status.mjs";
test("battery metadata preserves zero, strips extras and rejects stale/invalid samples", () => {
  const now = 1800000000000;
  const sample = { percent: 0, charging: true, observed_at_ms: now };
  assert.deepEqual(batteryStatus({...sample, unrelated: "discard"}, now), sample);
  for (const value of [undefined, {}, {...sample, percent: 101}, {...sample, percent: -1},
    {...sample, percent: "82"}, {...sample, charging: "true"},
    {...sample, observed_at_ms: now - 300000}, {...sample, observed_at_ms: now + 60001}]) {
    assert.equal(batteryStatus(value, now), null);
  }
});
