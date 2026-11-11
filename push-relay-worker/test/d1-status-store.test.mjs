import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { D1StatusStore } from "../src/d1-status-store.mjs";

class FakeD1 {
  constructor() {
    this.devices = new Map();
    this.heartbeats = new Map();
    this.events = new Map();
    this.tombstones = new Set();
  }

  prepare(sql) {
    return { bind: (...values) => ({
      first: async () => this.first(sql, values),
      all: async () => ({ results: this.all(sql, values) }),
      run: async () => ({ meta: { changes: this.run(sql, values) } }),
    }) };
  }

  async batch(statements) {
    for (const statement of statements) await statement.run();
  }

  first(sql, values) {
    if (sql.includes("SELECT record, deleted FROM relay_devices")) {
      const record = this.devices.get(values[0]);
      return record ? { record: JSON.stringify(record), deleted: this.tombstones.has(values[0]) ? 1 : 0 } : null;
    }
    if (sql.includes("SELECT 1 FROM relay_devices")) {
      const record = this.devices.get(values[0]);
      return record && !this.tombstones.has(values[0]) && record.secret_hash === values[1] ? { 1: 1 } : null;
    }
    if (sql.includes("SELECT h.record FROM relay_heartbeats")) {
      const candidates = [...this.heartbeats.entries()]
        .filter(([key]) => key.startsWith(`${values[0]}:`))
        .sort(([, a], [, b]) => b.received_at_ms - a.received_at_ms);
      return candidates[0] ? { record: JSON.stringify(candidates[0][1].record) } : null;
    }
    return null;
  }

  all(sql, values) {
    if (sql.includes("SELECT h.record FROM relay_heartbeats") && sql.includes("ORDER BY h.received_at_ms")) {
      return [...this.heartbeats.entries()]
        .filter(([key]) => key.startsWith(`${values[0]}:`))
        .sort(([, a], [, b]) => b.received_at_ms - a.received_at_ms)
        .map(([, value]) => ({ record: JSON.stringify(value.record) }));
    }
    if (sql.includes("SELECT record FROM relay_dashboard_events")) {
      return [...this.events.values()]
        .filter(event => event.expires_at_ms > values[0])
        .sort((a, b) => a.event_key.localeCompare(b.event_key))
        .slice(0, values[1])
        .map(event => ({ record: JSON.stringify(event.record) }));
    }
    return [];
  }

  run(sql, values) {
    if (sql.includes("INSERT INTO relay_devices")) {
      if (!this.devices.has(values[0]) || this.tombstones.has(values[0])) {
        this.devices.set(values[0], JSON.parse(values[2]));
        this.tombstones.delete(values[0]);
        return 1;
      }
      if (this.devices.get(values[0]).secret_hash === values[1]) {
        this.devices.set(values[0], JSON.parse(values[2]));
        return 1;
      }
      return 0;
    }
    if (sql.includes("INSERT INTO relay_heartbeats")) {
      const [agentID, receivedAt, encoded, deviceID, secretHash] = values;
      const device = this.devices.get(deviceID);
      if (!device || this.tombstones.has(deviceID) || device.secret_hash !== secretHash) return 0;
      const key = `${deviceID}:${agentID}`;
      const record = JSON.parse(encoded);
      if (!this.heartbeats.has(key) || receivedAt >= this.heartbeats.get(key).received_at_ms) {
        this.heartbeats.set(key, { received_at_ms: receivedAt, record });
        return 1;
      }
      return 0;
    }
    if (sql.includes("INSERT INTO relay_dashboard_events")) {
      this.events.set(values[0], { event_key: values[0], record: JSON.parse(values[1]), expires_at_ms: values[2] });
      return 1;
    }
    if (sql.includes("DELETE FROM relay_dashboard_events")) {
      for (const [key, event] of this.events) if (event.expires_at_ms <= values[0]) this.events.delete(key);
      return 1;
    }
    return 0;
  }
}

test("D1 status store keeps registration, heartbeat and event data out of DO storage", async () => {
  const database = new FakeD1();
  const store = new D1StatusStore(database);
  const device = { device_id: "phone-1", secret_hash: "hash-1", environment: "sandbox" };
  assert.equal(await store.writeDevice(device.device_id, device), true);
  assert.deepEqual(await store.deviceRow(device.device_id), { record: JSON.stringify(device), deleted: 0 });

  const heartbeat = { agent_id: "agent-1", received_at_ms: 100, at_ok: true };
  assert.equal(await store.writeHeartbeat(device.device_id, heartbeat.agent_id, heartbeat, device.secret_hash), true);
  assert.deepEqual(await store.heartbeats(device.device_id), [heartbeat]);
  assert.deepEqual(await store.latestHeartbeat(device.device_id), heartbeat);

  await store.writeEvent("dashboard:event:1", { type: "registration" }, 60);
  assert.deepEqual(await store.events(60), [{ type: "registration" }]);
});

test("D1 migration contains tombstones and separate bounded tables", async () => {
  const migration = await readFile(new URL("../migrations/0001_relay_status.sql", import.meta.url), "utf8");
  assert.match(migration, /CREATE TABLE relay_devices/);
  assert.match(migration, /CREATE TABLE relay_heartbeats/);
  assert.match(migration, /CREATE TABLE relay_dashboard_events/);
  assert.match(migration, /deleted INTEGER NOT NULL DEFAULT 0/);
});
