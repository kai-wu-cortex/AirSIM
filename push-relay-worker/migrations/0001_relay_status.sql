-- Optional RELAY_DB backend. COMMANDS, MEDIA and call lifecycle state stay in DOs.
CREATE TABLE relay_devices (
  device_id TEXT PRIMARY KEY,
  secret_hash TEXT,
  record TEXT,
  deleted INTEGER NOT NULL DEFAULT 0 CHECK (deleted IN (0, 1))
);

CREATE TABLE relay_heartbeats (
  device_id TEXT NOT NULL REFERENCES relay_devices(device_id),
  agent_id TEXT NOT NULL,
  received_at_ms INTEGER NOT NULL,
  record TEXT NOT NULL,
  PRIMARY KEY (device_id, agent_id)
);
CREATE INDEX relay_heartbeats_latest
  ON relay_heartbeats(device_id, received_at_ms DESC, agent_id);

CREATE TABLE relay_dashboard_events (
  event_key TEXT PRIMARY KEY,
  record TEXT NOT NULL,
  expires_at_ms INTEGER NOT NULL
);
CREATE INDEX relay_dashboard_events_expiry ON relay_dashboard_events(expires_at_ms);
