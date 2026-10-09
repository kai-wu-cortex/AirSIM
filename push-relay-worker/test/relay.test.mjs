import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, webcrypto } from "node:crypto";
import test from "node:test";
import worker, {
  bindMediaOwner,
  applyCallLifecycle,
  callControlMetadata,
  CallMediaSession,
  createProviderToken,
  DeviceCommandSession,
  selectMediaTransport,
  validateRegistration,
} from "../src/index.mjs";
import { AgentStatusRegistry } from "../src/status-store.mjs";

globalThis.crypto ??= webcrypto;

class MemoryKV {
  constructor() { this.values = new Map(); }
  async get(key) { return this.values.get(key) ?? null; }
  async put(key, value) { this.values.set(key, value); }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "", limit = 1000 } = {}) {
    return {
      keys: [...this.values.keys()].filter((key) => key.startsWith(prefix)).sort().slice(0, limit).map((name) => ({ name })),
      list_complete: true,
    };
  }
}

class WriteLimitedKV extends MemoryKV {
  async put() { throw new Error("KV daily write limit reached"); }
}

class ListLimitedKV extends MemoryKV {
  async list() { throw new Error("KV daily list limit reached"); }
}

class CountingKV extends MemoryKV {
  constructor() {
    super();
    this.operations = { get: 0, put: 0, delete: 0, list: 0 };
  }
  async get(key) { this.operations.get += 1; return super.get(key); }
  async put(key, value) { this.operations.put += 1; return super.put(key, value); }
  async delete(key) { this.operations.delete += 1; return super.delete(key); }
  async list(options) { this.operations.list += 1; return super.list(options); }
  resetOperations() { this.operations = { get: 0, put: 0, delete: 0, list: 0 }; }
}

class MemoryDurableStorage {
  constructor() {
    this.values = new Map();
    this.alarmAt = null;
  }
  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, value); }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "" } = {}) {
    return new Map([...this.values].filter(([key]) => key.startsWith(prefix)));
  }
  async setAlarm(value) { this.alarmAt = Number(value); }
  async getAlarm() { return this.alarmAt; }
  async deleteAlarm() { this.alarmAt = null; }
}

class MemoryStatusNamespace {
  constructor() {
    this.storage = new MemoryDurableStorage();
    this.registry = new AgentStatusRegistry({ storage: this.storage });
  }
  idFromName(name) { return name; }
  get() { return { fetch: (request, options) => this.registry.fetch(new Request(request, options)) }; }
}

class UnavailableStatusNamespace {
  idFromName(name) { return name; }
  get() { return { fetch: async () => new Response("unavailable", { status: 503 }) }; }
}

class MemoryMediaSocket {
  constructor(role) {
    this.attachment = { role, owner: false, pendingControl: "" };
    this.sent = [];
    this.closed = false;
  }
  deserializeAttachment() { return this.attachment; }
  serializeAttachment(value) { this.attachment = value; }
  send(value) { this.sent.push(value); }
  close() { this.closed = true; }
}

class MemoryMediaState {
  constructor(sockets = []) { this.sockets = sockets; }
  getWebSockets(role) {
    return this.sockets.filter((socket) => !socket.closed && (!role || socket.attachment.role === role));
  }
}

class MemoryCommandState extends MemoryMediaState {
  constructor(sockets = []) {
    super(sockets);
    this.storage = new MemoryDurableStorage();
  }
}

class MemoryCommandNamespace {
  constructor() { this.sessions = new Map(); }
  idFromName(name) { return name; }
  get(id) {
    if (!this.sessions.has(id)) {
      const state = new MemoryCommandState();
      this.sessions.set(id, { state, session: new DeviceCommandSession(state) });
    }
    const value = this.sessions.get(id);
    return { fetch: (request, options) => value.session.fetch(new Request(request, options)) };
  }
  addAgent(deviceID, socket = new MemoryMediaSocket("agent")) {
    this.get(deviceID);
    this.sessions.get(deviceID).state.sockets.push(socket);
    return socket;
  }
  session(deviceID) { this.get(deviceID); return this.sessions.get(deviceID).session; }
}

function testEnvironment() {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return {
    DEVICES: new MemoryKV(),
    APNS_TEAM_ID: "TEAMTEST01",
    APNS_KEY_ID: "KEYTEST001",
    APNS_P8: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    ALLOWED_BUNDLE_ID: "com.example.airsim",
    DASHBOARD_TOKEN: "dashboard-test-token-0123456789",
  };
}

function post(path, value) {
  return new Request(`https://push.airsim.example${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  });
}

const registration = {
  device_id: "iphone-air",
  device_secret: "s".repeat(32),
  voip_token: "a".repeat(64),
  alert_token: "b".repeat(64),
  watch_voip_token: "c".repeat(64),
  watch_bundle_id: "com.example.airsim.watchkitapp",
  live_activity_push_to_start_token: "d".repeat(64),
  bundle_id: "com.example.airsim",
  environment: "sandbox",
  relay_url: "https://push.airsim.example",
};

test("health and registration persist without returning credentials", async () => {
  const env = testEnvironment();
  const health = await worker.fetch(new Request("https://push.airsim.example/healthz"), env);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).version, "0.2.1");
  const response = await worker.fetch(post("/v1/devices/register", registration), env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { registered: true });
  const stored = JSON.parse(await env.DEVICES.get("device:iphone-air"));
  assert.equal(stored.device_secret, undefined);
  assert.equal(stored.secret_hash.length, 64);
});

test("device registration remains available when KV daily writes are exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new WriteLimitedKV();
  env.STATUS = new MemoryStatusNamespace();

  const response = await worker.fetch(post("/v1/devices/register", registration), env);

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { registered: true });
  const stored = await env.STATUS.storage.get("device:iphone-air");
  assert.equal(stored.device_secret, undefined);
  assert.equal(stored.secret_hash.length, 64);
  const heartbeat = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.42",
    at_ok: true,
    cellular_state: "registered",
  }), env);
  assert.equal(heartbeat.status, 202);
});

test("incoming call delivery remains available when KV daily writes are exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new WriteLimitedKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("", { status: 200 });
  try {
    const now = Date.now();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call",
      device_id: registration.device_id,
      device_secret: registration.device_secret,
      call_id: "quota-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "quota-call-secret-0123456789abcdef",
      number: "10010",
      issued_at: new Date(now).toISOString(),
      expires_at: new Date(now + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("healthy status registry keeps heartbeat and dashboard refresh off KV", async () => {
  const env = testEnvironment();
  env.DEVICES = new CountingKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  env.DEVICES.resetOperations();

  assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.43",
    at_ok: true,
    cellular_state: "registered",
  }), env)).status, 202);
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  assert.equal((await response.json()).metrics.online, 1);
  assert.deepEqual(env.DEVICES.operations, { get: 0, put: 0, delete: 0, list: 0 });
});

test("different devices register and authenticate independently", async () => {
  const env = testEnvironment();
  const second = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
    alert_token: "f".repeat(64),
  };
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/devices/register", second), env)).status, 200);

  for (const device of [registration, second]) {
    const response = await worker.fetch(post("/v1/events/heartbeat", {
      event: "agent_heartbeat",
      device_id: device.device_id,
      device_secret: device.device_secret,
      agent_version: "0.3.40",
      at_ok: true,
      cellular_state: "registered",
    }), env);
    assert.equal(response.status, 202);
  }
  assert.notEqual(
    (await env.DEVICES.get(`device:${registration.device_id}`)),
    (await env.DEVICES.get(`device:${second.device_id}`)),
  );
});

test("cloud dial and SMS commands are authenticated, device-scoped, and return Agent results", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  const second = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
    alert_token: "f".repeat(64),
  };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/devices/register", second), env);
  const agent = env.COMMANDS.addAgent(registration.device_id);
  const commandID = "2d33c399-1030-4e9a-90ea-bb429e16ac5a";
  const dial = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: commandID,
    type: "dial",
    number: "+86 186-8867-2253",
  }), env);
  assert.equal(dial.status, 202);
  const accepted = await dial.json();
  assert.equal(accepted.agent_connected, true);
  assert.equal(accepted.call.call_uuid.length, 36);
  assert.match(accepted.call.media_url, /^wss:\/\/push\.airsim\.example\/v1\/calls\//);
  assert.equal(agent.sent.length, 1);
  const delivered = JSON.parse(agent.sent[0]);
  assert.equal(delivered.number, "+8618688672253");
  assert.equal(delivered.call.direction, "outgoing");
  assert.equal(delivered.call.call_secret, accepted.call.call_secret);

  await env.COMMANDS.session(registration.device_id).webSocketMessage(agent, JSON.stringify({
    command_id: commandID,
    status: "completed",
    result: { dialing: true },
  }));
  const completed = await worker.fetch(post("/v1/commands/result", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: commandID,
  }), env);
  assert.equal(completed.status, 200);
  assert.equal((await completed.json()).result.dialing, true);

  const isolated = await worker.fetch(post("/v1/commands/result", {
    device_id: second.device_id,
    device_secret: second.device_secret,
    command_id: commandID,
  }), env);
  assert.equal(isolated.status, 404);
  const forged = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: second.device_secret,
    command_id: crypto.randomUUID(),
    type: "send_sms",
    number: "10086",
    message: "测试",
  }), env);
  assert.equal(forged.status, 401);
});

test("Watch dial can request legacy PCM during a WebRTC rollout", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  env.WEBRTC_TRANSPORT_READY = "true";
  env.WEBRTC_ROLLOUT_PERCENT = "100";
  const capable = {
    ...registration,
    media_transport: "webrtc",
    app_media_capabilities: ["legacy_pcm", "webrtc"],
    agent_media_capabilities: ["legacy_pcm", "webrtc"],
  };
  assert.equal((await worker.fetch(post("/v1/devices/register", capable), env)).status, 200);
  env.COMMANDS.addAgent(registration.device_id);
  const dial = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: crypto.randomUUID(),
    type: "dial",
    number: "10086",
    media_transport: "legacy_pcm",
  }), env);
  assert.equal(dial.status, 202);
  assert.equal((await dial.json()).call.media_transport, "legacy_pcm");
  const invalid = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: crypto.randomUUID(),
    type: "dial",
    number: "10086",
    media_transport: "webrtc",
  }), env);
  assert.equal(invalid.status, 400);
});

test("call control is durable, idempotent, and delivered after the Agent reconnects", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 7,
    direction: "incoming",
    secret_hash: "unused-by-device-authenticated-control",
    expires_at: new Date(Date.now() + 45_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const body = {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    action: "end",
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 7,
    command_id: commandID,
    trace_id: "9f9dc60b",
    owner: "iphone",
  };

  const first = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(first.status, 202);
  assert.deepEqual(await first.json(), {
    accepted: true,
    command_id: commandID,
    status: "pending",
    agent_connected: false,
  });
  const second = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(second.status, 202);
  assert.equal((await second.json()).duplicate, true);
  const collision = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, {
    ...body,
    action: "reject",
  }), env);
  assert.equal(collision.status, 409);
  const state = env.COMMANDS.sessions.get(registration.device_id).state;
  assert.equal((await state.storage.list({ prefix: "command:" })).size, 1);
  assert.ok((await state.storage.getAlarm()) > Date.now());

  const agent = env.COMMANDS.addAgent(registration.device_id);
  await env.COMMANDS.session(registration.device_id).flushPending(agent);
  assert.equal(agent.sent.length, 1);
  const delivered = JSON.parse(agent.sent[0]);
  assert.equal(delivered.type, "call_control");
  assert.equal(delivered.action, "end");
  assert.equal(delivered.call.call_uuid, callUUID);
  assert.equal(delivered.call.generation, 7);

  await env.COMMANDS.session(registration.device_id).webSocketMessage(agent, JSON.stringify({
    command_id: commandID,
    status: "completed",
    result: { ended: true, modem_confirmed: true, clcc_attempts: 2 },
  }));
  const result = await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/actions/${commandID}`,
    {
      headers: {
        authorization: `Bearer ${registration.device_secret}`,
        "x-airsim-device-id": registration.device_id,
      },
    },
  ), env);
  assert.equal(result.status, 200);
  const completed = await result.json();
  assert.equal(completed.status, "completed");
  assert.equal(completed.result.modem_confirmed, true);
  assert.equal(completed.result.clcc_attempts, 2);

  const completedDuplicate = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(completedDuplicate.status, 202);
  assert.deepEqual(await completedDuplicate.json(), {
    accepted: true,
    command_id: commandID,
    status: "completed",
    agent_connected: true,
    duplicate: true,
    result: { ended: true, modem_confirmed: true, clcc_attempts: 2 },
  });
});

test("call control rejects stale generations and cross-device reads", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  const secondDevice = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
  };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/devices/register", secondDevice), env);
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 3,
    direction: "incoming",
    expires_at: new Date(Date.now() + 45_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const stale = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    action: "end",
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 2,
    command_id: commandID,
    trace_id: "trace-stale",
    owner: "iphone",
  }), env);
  assert.equal(stale.status, 409);

  const crossDevice = await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/actions/${commandID}`,
    {
      headers: {
        authorization: `Bearer ${secondDevice.device_secret}`,
        "x-airsim-device-id": secondDevice.device_id,
      },
    },
  ), env);
  assert.equal(crossDevice.status, 403);
});

test("call control alarm backs off and expires an unconfirmed command without an Agent", async () => {
  const state = new MemoryCommandState();
  const storage = state.storage;
  const session = new DeviceCommandSession(state, {});
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const command = {
    command_id: commandID,
    type: "call_control",
    action: "end",
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9" },
  };
  const accepted = await session.fetch(post("/enqueue", command));
  assert.equal(accepted.status, 202);
  const key = `command:${commandID}`;
  let stored = await storage.get(key);
  const firstAlarm = await storage.getAlarm();
  assert.ok(firstAlarm >= Date.now());
  assert.ok(firstAlarm <= Date.now() + 1_100);

  await session.alarm();
  stored = await storage.get(key);
  assert.equal(stored.retry_count, 1);
  const secondAlarm = await storage.getAlarm();
  assert.ok(secondAlarm >= Date.now() + 1_900);
  assert.ok(secondAlarm <= Date.now() + 2_100);

  stored.expires_at_ms = Date.now() - 1;
  await storage.put(key, stored);

  await session.alarm();

  const expired = await storage.get(key);
  assert.equal(expired.status, "expired");
  assert.match(expired.error, /过期/);
  assert.equal(await storage.getAlarm(), null);
});

test("unconfirmed hangup creates exactly one rescue command after eight seconds", async () => {
  const state = new MemoryCommandState();
  const session = new DeviceCommandSession(state, {});
  const parentID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  await session.fetch(post("/enqueue", {
    command_id: parentID,
    type: "call_control",
    action: "end",
    owner: "iphone",
    trace_id: "trace-rescue",
    issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_id: "call-9", call_uuid: callUUID, generation: 7, direction: "incoming" },
  }));
  const parentKey = `command:${parentID}`;
  const parent = await state.storage.get(parentKey);
  parent.rescue_due_at_ms = Date.now() - 1;
  await state.storage.put(parentKey, parent);

  await session.alarm();
  await session.alarm();

  const records = await state.storage.list({ prefix: "command:" });
  const rescues = [...records.values()].filter((record) =>
    record.command?.action === "rescue_hangup");
  assert.equal(rescues.length, 1);
  assert.equal(rescues[0].command.parent_command_id, parentID);
  assert.equal(rescues[0].command.call.call_uuid, callUUID);
  assert.equal(rescues[0].command.call.generation, 7);
  const updatedParent = await state.storage.get(parentKey);
  assert.equal(updatedParent.rescue_command_id, rescues[0].command.command_id);

  const duplicate = await session.fetch(post("/enqueue", parent.command));
  const duplicateReceipt = await duplicate.json();
  assert.equal(duplicateReceipt.rescue_command_id, rescues[0].command.command_id);
});

test("heartbeat pull completes a rescue and propagates its modem result to the parent", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const parentID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const session = env.COMMANDS.session(registration.device_id);
  await session.fetch(post("/enqueue", {
    command_id: parentID,
    type: "call_control",
    action: "end",
    owner: "iphone",
    trace_id: "trace-rescue",
    issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_id: "call-9", call_uuid: callUUID, generation: 7, direction: "incoming" },
  }));
  const parentKey = `command:${parentID}`;
  const parent = await env.COMMANDS.sessions.get(registration.device_id).state.storage.get(parentKey);
  parent.rescue_due_at_ms = Date.now() - 1;
  await env.COMMANDS.sessions.get(registration.device_id).state.storage.put(parentKey, parent);
  await session.alarm();

  const pulled = await worker.fetch(post("/v1/commands/pull", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  assert.equal(pulled.status, 200);
  const batch = await pulled.json();
  const rescue = batch.commands.find((command) => command.action === "rescue_hangup");
  assert.ok(rescue);
  assert.equal(rescue.parent_command_id, parentID);

  const completed = await worker.fetch(post("/v1/commands/complete", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: rescue.command_id,
    status: "completed",
    result: { ended: true, modem_confirmed: true, clcc_attempts: 1 },
  }), env);
  assert.equal(completed.status, 202);

  const parentResult = await session.fetch(new Request(
    `https://commands.internal/result/${parentID}?call_uuid=${callUUID}`,
  ));
  const parentReceipt = await parentResult.json();
  assert.equal(parentReceipt.status, "completed");
  assert.equal(parentReceipt.result.modem_confirmed, true);
  assert.equal(parentReceipt.rescue_command_id, rescue.command_id);
});

test("dashboard is public as a shell but protects and sanitizes operational data", async () => {
  const env = testEnvironment();
  const page = await worker.fetch(new Request("https://push.airsim.example/dashboard"), env);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  assert.match(await page.text(), /通信中继/);

  const denied = await worker.fetch(new Request("https://push.airsim.example/dashboard/api/summary"), env);
  assert.equal(denied.status, 401);

  await worker.fetch(post("/v1/devices/register", registration), env);
  await env.DEVICES.put(`heartbeat:${registration.device_id}`, JSON.stringify({
    received_at_ms: Date.now(), agent_version: "0.3.38", at_ok: true,
    cellular_state: "registered", ecm_carrier: "1", signal_dbm: -73,
  }));
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);
  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.devices[0].environment, "sandbox");
  assert.equal(summary.devices[0].push.iphone, true);
  assert.notEqual(summary.devices[0].id, registration.device_id);
  const serialized = JSON.stringify(summary);
  for (const secret of [registration.device_secret, registration.voip_token, registration.alert_token]) {
    assert.equal(serialized.includes(secret), false);
  }
});

test("dashboard API reports missing server-side authentication configuration", async () => {
  const env = { ...testEnvironment(), DASHBOARD_TOKEN: "" };
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: "Bearer anything" } },
  ), env);
  assert.equal(response.status, 503);
});

test("dashboard falls back to KV mirrors when status registry is unavailable", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  await env.DEVICES.put(`heartbeat:${registration.device_id}`, JSON.stringify({
    received_at_ms: Date.now(), agent_version: "0.3.43", at_ok: true,
    cellular_state: "registered", ecm_carrier: "1", signal_dbm: -71,
  }));
  env.STATUS = new UnavailableStatusNamespace();

  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.service.version, "0.2.1");
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.devices[0].agent_version, "0.3.43");
});

test("dashboard remains available when KV list quota is exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new ListLimitedKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.43",
    at_ok: true,
    cellular_state: "registered",
  }), env)).status, 202);

  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.events[0].type, "registration");
});

test("dashboard virtual call selects an opaque device and never stores TTS content", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const summaryResponse = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);
  const summary = await summaryResponse.json();
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(new Request(
      "https://push.airsim.example/dashboard/api/virtual-call",
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.DASHBOARD_TOKEN}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          device_id: summary.devices[0].control_id,
          title: "Vibe Coding",
          content: "内容已完成，请查看这条消息。",
        }),
      },
    ), env);
    assert.equal(response.status, 202);
    assert.equal((await response.json()).sent, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-push-type"], "voip");
  assert.equal(captured[0].payload.virtual_call, true);
  assert.equal(captured[0].payload.caller_name, "Vibe Coding");
  assert.equal(captured[0].payload.tts_text, "内容已完成，请查看这条消息。");
  assert.equal(JSON.stringify([...env.DEVICES.values.values()]).includes("内容已完成"), false);
});

test("dashboard virtual call requires auth, validates fields, and rate limits a device", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const summary = await (await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env)).json();
  const request = (headers, content = "测试播报") => new Request(
    "https://push.airsim.example/dashboard/api/virtual-call",
    { method: "POST", headers, body: JSON.stringify({ device_id: summary.devices[0].control_id, title: "测试来电", content }) },
  );
  assert.equal((await worker.fetch(request({}), env)).status, 401);
  assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }, ""), env)).status, 400);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("", { status: 200 });
  try {
    assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }), env)).status, 202);
    assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }), env)).status, 429);
  } finally { globalThis.fetch = originalFetch; }
});

test("relay sends iPhone VoIP, Watch VoIP, mirror alert, and SMS on distinct APNs topics", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const call = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-1",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      number: "10010", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(call.status, 202);
    const sms = await worker.fetch(post("/v1/events/sms", {
      event: "incoming_sms", device_id: registration.device_id,
      device_secret: registration.device_secret, delivery_id: "sms-1",
      sender: "10010", content: "余额提醒", timestamp: now.toISOString(),
    }), env);
    assert.equal(sms.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 5);
  assert.equal(captured[0].options.headers["apns-push-type"], "voip");
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.voip");
  assert.equal(captured[0].options.headers["apns-collapse-id"], "d9b59660-05bb-4ea8-9aeb-4505b35c93f9");
  assert.equal(captured[0].payload.call_secret, "watch-call-secret-0123456789abcdef");
  assert.equal(captured[0].payload.media_url, "wss://push.airsim.example/v1/calls/d9b59660-05bb-4ea8-9aeb-4505b35c93f9/connect");
  assert.equal(captured[1].options.headers["apns-push-type"], "voip");
  assert.equal(captured[1].options.headers["apns-topic"], "com.example.airsim.watchkitapp.voip");
  assert.equal(captured[1].options.headers["apns-collapse-id"], "d9b59660-05bb-4ea8-9aeb-4505b35c93f9");
  assert.equal(captured[1].payload.event, "incoming_call");
  assert.equal(captured[1].payload.call_secret, "watch-call-secret-0123456789abcdef");
  assert.equal(captured[2].options.headers["apns-push-type"], "alert");
  assert.equal(captured[2].options.headers["apns-topic"], "com.example.airsim");
  assert.equal(captured[2].payload.event, "incoming_call_mirror");
  assert.equal(captured[2].payload.aps.alert.title, "10010");
  assert.equal(captured[3].options.headers["apns-push-type"], "liveactivity");
  assert.equal(captured[3].options.headers["apns-topic"], "com.example.airsim.push-type.liveactivity");
  assert.equal(captured[3].payload.aps.event, "start");
  assert.equal(captured[3].payload.aps["input-push-token"], 1);
  assert.equal(captured[3].payload.aps["attributes-type"], "AirSIMCallActivityAttributes");
  assert.equal(captured[3].payload.aps["content-state"].callID, "call-1");
  assert.equal(captured[4].options.headers["apns-push-type"], "alert");
  assert.equal(captured[4].options.headers["apns-topic"], "com.example.airsim");
  assert.equal(captured[4].payload.aps.alert.body, "余额提醒");

  const storedCall = JSON.parse(await env.DEVICES.get("call:d9b59660-05bb-4ea8-9aeb-4505b35c93f9"));
  assert.equal(storedCall.device_id, registration.device_id);
  assert.equal(storedCall.call_id, "call-1");
  assert.equal(storedCall.secret_hash.length, 64);
  assert.equal(storedCall.call_secret, undefined);
});

test("incoming call retries deduplicate VoIP and Watch alert by call UUID", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const payload = {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-dedupe",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      number: "10086", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    };
    const first = await worker.fetch(post("/v1/events/call", payload), env);
    const second = await worker.fetch(post("/v1/events/call", payload), env);
    assert.equal(first.status, 202);
    assert.equal(second.status, 202);
    assert.deepEqual(await second.json(), { duplicate: true });
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 4);
});

test("registered ActivityKit update token is preferred over push-to-start and owner updates it", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const registered = await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    activity_id: "activity-1",
    call_id: "",
    update_token: "e".repeat(64),
  }), env);
  assert.equal(registered.status, 200);

  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-live",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      number: "10010", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    await worker.fetch(post("/v1/events/call-owner", {
      event: "call_owner", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-live",
      call_uuid: "d9b59660-05bb-4ea8-9aEB-4505b35c93f9",
      owner: "iphone", phase: "active",
    }), env);
  } finally {
    globalThis.fetch = originalFetch;
  }
  const live = captured.filter(item => item.options.headers["apns-push-type"] === "liveactivity");
  assert.equal(live.length, 2);
  assert.match(live[0].url, /e{64}$/);
  assert.equal(live[0].payload.aps.event, "update");
  assert.equal(live[0].payload.aps["content-state"].phase, "incoming");
  assert.equal(live[1].payload.aps["content-state"].phase, "active");
});

test("watch token requires the signed companion bundle id", () => {
  assert.equal(
    validateRegistration({ ...registration, watch_bundle_id: "com.attacker.watch" }, "com.example.airsim"),
    "watch bundle id is not allowed",
  );
  assert.equal(
    validateRegistration({ ...registration, watch_bundle_id: "" }, "com.example.airsim"),
    "watch bundle id is not allowed",
  );
});

test("Watch-only VoIP registration can receive a native Watch call", async () => {
  const env = testEnvironment();
  const watchOnly = { ...registration, voip_token: "", alert_token: "", live_activity_push_to_start_token: "" };
  assert.equal((await worker.fetch(post("/v1/devices/register", watchOnly), env)).status, 200);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "watch-only-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.watchkitapp.voip");
});

test("Watch answer sends a background ownership event to iPhone CallKit", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(post("/v1/events/call-owner", {
      event: "call_owner", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "watch-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      owner: "watch", phase: "active",
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-push-type"], "background");
  assert.equal(captured[0].options.headers["apns-priority"], "5");
  assert.equal(captured[0].payload.event, "call_owner");
  assert.equal(captured[0].payload.owner, "watch");
});

test("legacy Agent call remains available on iPhone while Watch media is skipped", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "legacy-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 3);
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.voip");
  assert.equal(captured[1].options.headers["apns-push-type"], "alert");
  assert.equal(captured[2].options.headers["apns-push-type"], "liveactivity");
});

test("call websocket authenticates the per-call secret before reaching its durable object", async () => {
  const env = testEnvironment();
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const secret = "watch-call-secret-0123456789abcdef";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-media",
    secret_hash: createHash("sha256").update(secret).digest("hex"),
    expires_at: new Date(Date.now() - 10_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const forwarded = [];
  env.MEDIA = {
    idFromName(name) { return name; },
    get(id) {
      return {
        async fetch(request) {
          forwarded.push({ id, role: request.headers.get("x-airsim-role") });
          return new Response("forwarded", { status: 200 });
        },
      };
    },
  };

  const connect = (role, token) => worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/connect?role=${role}&token=${token}`,
    { headers: { upgrade: "websocket" } },
  ), env);

  assert.equal((await connect("watch", "wrong-secret-value-0123456789")).status, 401);
  assert.equal((await connect("attacker", secret)).status, 400);
  assert.equal((await connect("watch", secret)).status, 200);
  assert.equal((await connect("iphone", secret)).status, 200);
  assert.deepEqual(forwarded, [
    { id: callUUID, role: "watch" },
    { id: callUUID, role: "iphone" },
  ]);
});

test("relay binds the authenticated client role into call control", () => {
  assert.equal(
    bindMediaOwner('{"action":"answer","call_id":"call-9"}', "iphone"),
    '{"action":"answer","call_id":"call-9","owner":"iphone"}',
  );
  assert.equal(bindMediaOwner(new Uint8Array([1, 2]), "iphone") instanceof Uint8Array, true);
});

test("relay preserves call control trace identity in receipts", () => {
  const message = bindMediaOwner(JSON.stringify({
    action: "end",
    call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 7,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
    trace_id: "9f9dc60b",
  }), "iphone");
  assert.deepEqual(callControlMetadata(message), {
    action: "end",
    call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 7,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
    trace_id: "9f9dc60b",
  });
});

test("relay queues answer until the Agent media socket connects", () => {
  const iphone = new MemoryMediaSocket("iphone");
  const state = new MemoryMediaState([iphone]);
  const session = new CallMediaSession(state, {});

  session.webSocketMessage(iphone, JSON.stringify({
    action: "answer", call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", generation: 2,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", trace_id: "9f9dc60b",
  }));

  assert.equal(iphone.attachment.owner, true);
  assert.match(iphone.attachment.pendingControl, /"action":"answer"/);
  assert.match(iphone.attachment.pendingControl, /"owner":"iphone"/);
  assert.ok(iphone.sent.some((message) => message.includes("action_queued")));
  assert.ok(iphone.sent.some((message) => message.includes("9f9dc60b-3a36-4a0a-b87a-63a3ffb27145")));

  const agent = new MemoryMediaSocket("agent");
  state.sockets.push(agent);
  session.flushPendingControls(agent);

  assert.equal(agent.sent.length, 1);
  assert.match(agent.sent[0], /"action":"answer"/);
  assert.equal(iphone.attachment.pendingControl, "");
  assert.ok(iphone.sent.some((message) => message.includes("action_forwarded")));
});

test("relay forwards binary PCM in both directions only to the claimed iPhone", () => {
  const agent = new MemoryMediaSocket("agent");
  const iphone = new MemoryMediaSocket("iphone");
  const watch = new MemoryMediaSocket("watch");
  const state = new MemoryMediaState([agent, iphone, watch]);
  const session = new CallMediaSession(state, {});

  session.webSocketMessage(iphone, JSON.stringify({ action: "answer", call_id: "call-9" }));
  agent.sent = [];
  iphone.sent = [];
  watch.sent = [];

  const uplink = new Uint8Array([1, 2, 3, 4]);
  const downlink = new Uint8Array([5, 6, 7, 8]);
  session.webSocketMessage(iphone, uplink);
  session.webSocketMessage(agent, downlink);

  assert.deepEqual(agent.sent, [uplink]);
  assert.deepEqual(iphone.sent, [downlink]);
  assert.deepEqual(watch.sent, []);
});

test("media transport rollout is deterministic and always keeps legacy fallback", () => {
  const capable = {
    deviceID: "device-rollout-a",
    requested: "webrtc",
    appCapabilities: ["legacy_pcm", "webrtc"],
    agentCapabilities: ["legacy_pcm", "webrtc"],
  };
  assert.equal(selectMediaTransport({ ...capable, rolloutPercent: 0 }), "legacy_pcm");
  assert.equal(selectMediaTransport({ ...capable, rolloutPercent: 100 }), "webrtc");
  assert.equal(
    selectMediaTransport({ ...capable, rolloutPercent: 100 }),
    selectMediaTransport({ ...capable, rolloutPercent: 100 }),
  );
  assert.equal(selectMediaTransport({
    ...capable, agentCapabilities: ["legacy_pcm"], rolloutPercent: 100,
  }), "legacy_pcm");
  assert.equal(selectMediaTransport({
    ...capable, rolloutPercent: 100, forceLegacy: true,
  }), "legacy_pcm");
});

test("media relay survives 50 answer audio reconnect and hangup cycles without cross-device frames", () => {
  for (let round = 0; round < 50; round += 1) {
    const agent = new MemoryMediaSocket("agent");
    const iphone = new MemoryMediaSocket("iphone");
    const otherPhone = new MemoryMediaSocket("iphone");
    const state = new MemoryMediaState([agent, iphone, otherPhone]);
    const session = new CallMediaSession(state, {});
    const callID = `stress-${round}`;

    session.webSocketMessage(iphone, JSON.stringify({ action: "answer", call_id: callID }));
    agent.sent = [];
    iphone.sent = [];
    otherPhone.sent = [];
    const uplink = new Uint8Array([round, 1, 2, 3]);
    const downlink = new Uint8Array([round, 4, 5, 6]);
    session.webSocketMessage(iphone, uplink);
    session.webSocketMessage(agent, downlink);
    assert.deepEqual(agent.sent, [uplink], `round ${round} uplink`);
    assert.deepEqual(iphone.sent, [downlink], `round ${round} downlink`);
    assert.deepEqual(otherPhone.sent, [], `round ${round} isolation`);

    state.sockets.splice(state.sockets.indexOf(agent), 1);
    const reconnectedAgent = new MemoryMediaSocket("agent");
    state.sockets.push(reconnectedAgent);
    session.flushPendingControls(reconnectedAgent);
    session.webSocketMessage(iphone, JSON.stringify({ action: "end", call_id: callID }));
    assert.ok(
      reconnectedAgent.sent.some((message) => typeof message === "string" && message.includes('"action":"end"')),
      `round ${round} hangup`,
    );
    session.webSocketMessage(reconnectedAgent, JSON.stringify({
      status: "remote_ended", call_id: callID,
    }));
    session.webSocketClose(iphone, 1000, "call ended");
    assert.equal(session.ownerRole(), "", `round ${round} residual owner`);
  }
});

test("agent heartbeat lets iPhone distinguish cloud-only from fully offline", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const heartbeat = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.35",
    at_ok: true,
    cellular_state: "searching",
    cellular_registration: "搜索中",
    cellular_recovery: "正在自动选网",
    ecm_carrier: "1",
  }), env);
  assert.equal(heartbeat.status, 202);

  const status = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  assert.equal(status.status, 200);
  assert.deepEqual(await status.json(), {
    cloud_online: true,
    agent_id: "legacy",
    agent_version: "0.3.35",
    at_ok: true,
    cellular_state: "searching",
    cellular_registration: "搜索中",
    cellular_recovery: "正在自动选网",
    ecm_carrier: "1",
    active_agent_id: "legacy",
    agents: [{
      agent_id: "legacy",
      agent_version: "0.3.35",
      at_ok: true,
      cellular_state: "searching",
      cellular_registration: "搜索中",
      cellular_recovery: "正在自动选网",
      ecm_carrier: "1",
      cloud_online: true,
    }],
  });
});

test("device status keeps standalone and AVF agents as separate routes", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const heartbeat = (agentID, kind, name, number) => post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_id: agentID,
    agent_kind: kind,
    device_name: name,
    phone_number: number,
    agent_version: kind === "standalone" ? "standalone-0.1.0" : "0.4.4",
    at_ok: true,
    cellular_state: "registered",
  });

  assert.equal((await worker.fetch(heartbeat("xiaomi-standalone", "standalone", "Xiaomi 15", "+8613800000001"), env)).status, 202);
  await new Promise((resolve) => setTimeout(resolve, 2));
  assert.equal((await worker.fetch(heartbeat("samsung-avf", "avf", "Samsung Flip7", "+8613800000002"), env)).status, 202);

  const response = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  const status = await response.json();
  assert.equal(status.active_agent_id, "samsung-avf");
  assert.equal(status.agents.length, 2);
  assert.deepEqual(status.agents.map((agent) => agent.agent_id).sort(), ["samsung-avf", "xiaomi-standalone"]);
  assert.equal(status.agents.find((agent) => agent.agent_id === "xiaomi-standalone").phone_number, "+8613800000001");
});

test("wrong device secret is rejected before APNs", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const response = await worker.fetch(post("/v1/events/sms", {
    event: "incoming_sms", device_id: registration.device_id,
    device_secret: "wrong-secret-value", delivery_id: "sms-2",
    sender: "10010", content: "test", timestamp: new Date().toISOString(),
  }), env);
  assert.equal(response.status, 401);
});

test("registration is pinned to the signed app bundle", () => {
  assert.equal(validateRegistration({ ...registration, bundle_id: "com.attacker.app" }, "com.example.airsim"), "bundle id is not allowed");
});

test("provider JWT is ES256-shaped and names the Apple key", async () => {
  const env = testEnvironment();
  const token = await createProviderToken(env, Date.parse("2026-08-20T12:00:00Z"));
  const parts = token.split(".");
  assert.equal(parts.length, 3);
  const header = JSON.parse(Buffer.from(parts[0], "base64url").toString());
  const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString());
  assert.deepEqual(header, { alg: "ES256", kid: "KEYTEST001" });
  assert.equal(claims.iss, "TEAMTEST01");
  assert.equal(Buffer.from(parts[2], "base64url").length, 64);
});

test("Agent call-state end returns the current Live Activity to cloud standby", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id, device_secret: registration.device_secret,
    activity_id: "activity-state", call_id: "call-state", update_token: "f".repeat(64),
  }), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(post("/v1/events/call-state", {
      event: "call_state", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-state",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", phase: "ended",
    }), env);
    assert.equal(response.status, 202);
  } finally { globalThis.fetch = originalFetch; }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].payload.aps.event, "update");
  assert.equal(captured[0].payload.aps["content-state"].phase, "cloud_standby");
  assert.equal(captured[0].payload.aps["content-state"].displayName, "公网中继已连接");
});

test("call lifecycle reducer rejects stale and terminal resurrection events", () => {
  const base = {
    call_id: "call-state", call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 2, phase: "ended", source: "agent",
    timestamp: "2026-09-04T10:00:02.000Z", trace_id: "trace-ended",
  };
  assert.equal(applyCallLifecycle(base, {
    ...base, phase: "active", timestamp: "2026-09-04T10:00:03.000Z",
  }).accepted, false);
  assert.equal(applyCallLifecycle(base, {
    ...base, generation: 1, phase: "active", timestamp: "2026-09-04T10:00:03.000Z",
  }).reason, "stale_generation");
  const next = applyCallLifecycle(base, {
    ...base, generation: 3, phase: "ringing", timestamp: "2026-09-04T10:00:04.000Z",
  });
  assert.equal(next.accepted, true);
  assert.equal(next.snapshot.phase, "ringing");
});

test("expired ActivityKit token never turns a delivered VoIP call into a relay failure", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => new Response(
    options.headers["apns-push-type"] === "liveactivity" ? '{"reason":"BadDeviceToken"}' : "",
    { status: options.headers["apns-push-type"] === "liveactivity" ? 410 : 200 },
  );
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-expired-activity",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      number: "10086", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
    assert.equal((await response.json()).pushed, true);
  } finally { globalThis.fetch = originalFetch; }
});
