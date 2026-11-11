// D1 is authoritative when RELAY_DB is bound. Never use stale DO/KV data after
// a D1 failure or tombstone; an outage must not become an authentication bypass.
export class D1StorageError extends Error {
  constructor() { super("relay D1 storage unavailable"); }
}

export class D1StatusStore {
  constructor(database) { this.database = database; }

  async query(sql, values = [], method = "run") {
    try { return await this.database.prepare(sql).bind(...values)[method](); }
    catch { throw new D1StorageError(); }
  }

  async deviceRow(deviceID) {
    return this.query("SELECT record, deleted FROM relay_devices WHERE device_id = ?", [deviceID], "first");
  }

  async importDevice(deviceID, record) {
    // A concurrent registration or deletion always wins over the old snapshot.
    await this.query(`INSERT INTO relay_devices (device_id, secret_hash, record)
      VALUES (?, ?, ?) ON CONFLICT(device_id) DO NOTHING`,
    [deviceID, record.secret_hash, JSON.stringify(record)]);
    return this.deviceRow(deviceID);
  }

  async writeDevice(deviceID, record) {
    // Atomically protect first-registration races, not just the preceding read.
    const result = await this.query(`INSERT INTO relay_devices (device_id, secret_hash, record)
      VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET
      secret_hash = excluded.secret_hash, record = excluded.record, deleted = 0
      WHERE relay_devices.deleted = 1 OR relay_devices.secret_hash = excluded.secret_hash`,
    [deviceID, record.secret_hash, JSON.stringify(record)]);
    return result.meta.changes > 0;
  }

  async writeHeartbeat(deviceID, agentID, record, secretHash) {
    // Check auth in the write itself so a concurrent device deletion cannot
    // resurrect its heartbeat. One row per agent also supplies the latest view.
    const result = await this.query(`INSERT INTO relay_heartbeats
      (device_id, agent_id, received_at_ms, record)
      SELECT device_id, ?, ?, ? FROM relay_devices
      WHERE device_id = ? AND secret_hash = ? AND deleted = 0
      ON CONFLICT(device_id, agent_id) DO UPDATE SET
      received_at_ms = excluded.received_at_ms, record = excluded.record
      WHERE excluded.received_at_ms >= relay_heartbeats.received_at_ms`,
    [agentID, record.received_at_ms, JSON.stringify(record), deviceID, secretHash]);
    if (result.meta.changes > 0) return true;
    // A late, valid heartbeat is acknowledged without replacing fresher state.
    return Boolean(await this.query(`SELECT 1 FROM relay_devices
      WHERE device_id = ? AND secret_hash = ? AND deleted = 0`, [deviceID, secretHash], "first"));
  }

  async heartbeats(deviceID) {
    const result = await this.query(`SELECT h.record FROM relay_heartbeats h
      JOIN relay_devices d ON d.device_id = h.device_id
      WHERE h.device_id = ? AND d.deleted = 0 ORDER BY h.received_at_ms DESC, h.agent_id`,
    [deviceID], "all");
    return result.results.map(row => JSON.parse(row.record));
  }

  async latestHeartbeat(deviceID) {
    const row = await this.query(`SELECT h.record FROM relay_heartbeats h
      JOIN relay_devices d ON d.device_id = h.device_id
      WHERE h.device_id = ? AND d.deleted = 0
      ORDER BY h.received_at_ms DESC, h.agent_id LIMIT 1`, [deviceID], "first");
    return row ? JSON.parse(row.record) : null;
  }

  async deviceSummaries() {
    const summaries = [];
    let cursor = "";
    for (;;) {
      const page = await this.query(`SELECT d.device_id, d.record,
        (SELECT h.record FROM relay_heartbeats h WHERE h.device_id = d.device_id
          ORDER BY h.received_at_ms DESC, h.agent_id LIMIT 1) AS heartbeat
        FROM relay_devices d WHERE d.deleted = 0 AND d.device_id > ?
        ORDER BY d.device_id LIMIT 250`, [cursor], "all");
      summaries.push(...page.results.map(row => ({
        device: JSON.parse(row.record), heartbeat: row.heartbeat ? JSON.parse(row.heartbeat) : null,
      })));
      if (page.results.length < 250) return summaries;
      cursor = page.results.at(-1).device_id;
    }
  }

  async deleteDevice(deviceID) {
    // Keep the tombstone: old KV mirrors must never silently re-import a deletion.
    try {
      await this.database.batch([
        this.database.prepare(`INSERT INTO relay_devices (device_id, deleted) VALUES (?, 1)
          ON CONFLICT(device_id) DO UPDATE SET deleted = 1, secret_hash = NULL, record = NULL`).bind(deviceID),
        this.database.prepare("DELETE FROM relay_heartbeats WHERE device_id = ?").bind(deviceID),
      ]);
    } catch { throw new D1StorageError(); }
  }

  async writeEvent(key, record, ttlSeconds) {
    await this.query(`INSERT INTO relay_dashboard_events (event_key, record, expires_at_ms)
      VALUES (?, ?, ?) ON CONFLICT(event_key) DO UPDATE SET
      record = excluded.record, expires_at_ms = excluded.expires_at_ms`,
    [key, JSON.stringify(record), Date.now() + ttlSeconds * 1_000]);
  }

  async events(limit) {
    const count = Number.isFinite(Number(limit)) ? Math.max(1, Math.min(100, Math.floor(Number(limit)))) : 60;
    const result = await this.query(`SELECT record FROM relay_dashboard_events
      WHERE expires_at_ms > ? ORDER BY event_key LIMIT ?`, [Date.now(), count], "all");
    return result.results.map(row => JSON.parse(row.record));
  }

  async pruneEvents() {
    // Bound each cron's writes; reads filter expired rows even when a backlog remains.
    await this.query(`DELETE FROM relay_dashboard_events WHERE event_key IN
      (SELECT event_key FROM relay_dashboard_events WHERE expires_at_ms <= ?
        ORDER BY expires_at_ms LIMIT 1000)`, [Date.now()]);
  }
}
