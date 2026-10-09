import {
  dashboardAuthorized,
  dashboardHTMLResponse,
  dashboardSummary,
  dashboardVirtualCall,
  recordDashboardEvent,
} from "./dashboard.mjs";
import {
  deleteRelayState,
  readAgentHeartbeat,
  readAgentHeartbeats,
  readDeviceRecord,
  readRelayState,
  writeAgentHeartbeat,
  writeDeviceRecord,
  writeRelayState,
} from "./status-store.mjs";
export { AgentStatusRegistry } from "./status-store.mjs";

const MAX_BODY_BYTES = 64 * 1024;
const MAX_APNS_PAYLOAD_BYTES = 4096;
const TOKEN_PATTERN = /^[0-9a-f]{16,512}$/i;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const encoder = new TextEncoder();
const MEDIA_CLIENT_ROLES = new Set(["watch", "iphone"]);
const COMMAND_TYPES = new Set(["dial", "send_sms", "dtmf"]);
const MEDIA_TRANSPORTS = new Set(["legacy_pcm", "webrtc"]);

let cachedProviderToken = "";
let cachedProviderTokenAt = 0;
let cachedProviderTokenKey = "";

export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  },
};

export async function handleRequest(request, env) {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/") {
    return Response.redirect(`${url.origin}/dashboard`, 302);
  }
  if (request.method === "GET" && url.pathname === "/dashboard") {
    return dashboardHTMLResponse();
  }
  if (request.method === "GET" && url.pathname === "/dashboard/api/summary") {
    const auth = dashboardAuthorized(request, env);
    if (!auth.configured) return jsonResponse(503, { error: "dashboard is not configured" });
    if (!auth.authorized) return jsonResponse(401, { error: "unauthorized" });
    try {
      return jsonResponse(200, await dashboardSummary(env));
    } catch (error) {
      console.error("dashboard summary failed", safeError(error));
      return jsonResponse(500, { error: "dashboard temporarily unavailable" });
    }
  }
  if (request.method === "POST" && url.pathname === "/dashboard/api/virtual-call") {
    const auth = dashboardAuthorized(request, env);
    if (!auth.configured) return jsonResponse(503, { error: "dashboard is not configured" });
    if (!auth.authorized) return jsonResponse(401, { error: "unauthorized" });
    try {
      return await dashboardVirtualCall(request, env, sendAPNs);
    } catch (error) {
      console.error("dashboard virtual call failed", safeError(error));
      return jsonResponse(500, { error: "Relay 暂时不可用，请稍后重试" });
    }
  }
  if (request.method === "GET" && url.pathname === "/healthz") {
    return jsonResponse(200, { ok: true, service: "airsim-push-relay", version: "0.2.1" });
  }
  const callConnect = url.pathname.match(/^\/v1\/calls\/([0-9a-f-]+)\/connect$/i);
  if (request.method === "GET" && callConnect) {
    return connectCallMedia(request, env, callConnect[1]);
  }
  const callActionResult = url.pathname.match(
    /^\/v1\/calls\/([0-9a-f-]+)\/actions\/([0-9a-f-]+)$/i,
  );
  if (request.method === "GET" && callActionResult) {
    return readCallActionResult(request, env, callActionResult[1], callActionResult[2]);
  }
  const commandConnect = url.pathname.match(/^\/v1\/devices\/([^/]+)\/commands\/connect$/);
  if (request.method === "GET" && commandConnect) {
    return connectDeviceCommands(request, env, decodeURIComponent(commandConnect[1]));
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "method not allowed" });
  }
  try {
    if (url.pathname === "/v1/devices/register") {
      return await registerDevice(request, env);
    }
    if (url.pathname === "/v1/live-activities/register") {
      return await registerLiveActivity(request, env);
    }
    if (url.pathname === "/v1/events/call") {
      return await receiveCall(request, env);
    }
    if (url.pathname === "/v1/events/call-owner") {
      return await receiveCallOwner(request, env);
    }
    if (url.pathname === "/v1/events/call-state") {
      return await receiveCallState(request, env);
    }
    if (url.pathname === "/v1/events/sms") {
      return await receiveSMS(request, env);
    }
    if (url.pathname === "/v1/events/heartbeat") {
      return await receiveAgentHeartbeat(request, env);
    }
    if (url.pathname === "/v1/devices/status") {
      return await receiveDeviceStatus(request, env);
    }
    if (url.pathname === "/v1/commands/enqueue") {
      return await enqueueDeviceCommand(request, env);
    }
    if (url.pathname === "/v1/commands/result") {
      return await readDeviceCommandResult(request, env);
    }
    if (url.pathname === "/v1/commands/pull") {
      return await pullDeviceCommands(request, env);
    }
    if (url.pathname === "/v1/commands/complete") {
      return await completeDeviceCommand(request, env);
    }
    const callAction = url.pathname.match(/^\/v1\/calls\/([0-9a-f-]+)\/actions$/i);
    if (callAction) {
      return await enqueueCallAction(request, env, callAction[1]);
    }
    return jsonResponse(404, { error: "not found" });
  } catch (error) {
    console.error("relay request failed", safeError(error));
    return jsonResponse(500, { error: "relay internal error" });
  }
}

async function connectDeviceCommands(request, env, deviceID) {
  if (!nonEmpty(deviceID) || deviceID.length > 128 || !env.COMMANDS) {
    return jsonResponse(503, { error: "device command relay unavailable" });
  }
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return jsonResponse(426, { error: "websocket upgrade required" });
  }
  const authorization = request.headers.get("authorization") || "";
  const secret = authorization.match(/^Bearer\s+(.+)$/i)?.[1] || "";
  const authenticated = await authenticate({ device_id: deviceID, device_secret: secret }, env);
  if (authenticated.response) return authenticated.response;

  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(deviceID));
  const headers = new Headers(request.headers);
  headers.set("x-airsim-device-id", deviceID);
  return stub.fetch(new Request("https://commands.internal/connect", { headers }));
}

async function enqueueDeviceCommand(request, env) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "device command relay unavailable" });
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  const validation = validateDeviceCommand(value);
  if (validation) return jsonResponse(400, { error: validation });

  const command = {
    command_id: value.command_id.toLowerCase(),
    type: value.type,
    issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + (value.type === "send_sms" ? 5 : 2) * 60_000).toISOString(),
    number: normalizePhoneNumber(value.number),
    ...(value.type === "send_sms" ? { message: value.message.trim() } : {}),
  };
  let call = null;
  if (value.type === "dial") {
    const callUUID = crypto.randomUUID().toLowerCase();
    const callSecret = randomToken(32);
    const callID = `outgoing-${command.command_id}`;
    const origin = new URL(request.url).origin;
    // Watch 当前只支持 PCM；已认证的发起方可要求向后兼容的媒体格式。
    const mediaTransport = assignedMediaTransport(
      authenticated.device, env, value.media_transport === "legacy_pcm" ? "legacy_pcm" : ""
    );
    command.call = {
      call_id: callID,
      call_uuid: callUUID,
      generation: 1,
      call_secret: callSecret,
      relay_url: origin,
      direction: "outgoing",
      media_transport: mediaTransport,
    };
    await writeRelayState(env, `call:${callUUID}`, JSON.stringify({
      device_id: authenticated.device.device_id,
      call_id: callID,
      call_uuid: callUUID,
      generation: 1,
      direction: "outgoing",
      secret_hash: await sha256Hex(callSecret),
      expires_at: command.expires_at,
      media_expires_at: new Date(Date.now() + 5 * 60 * 60 * 1_000).toISOString(),
      media_transport: mediaTransport,
    }), 5 * 60 * 60);
    call = {
      call_id: callID,
      call_uuid: callUUID,
      generation: 1,
      call_secret: callSecret,
      media_url: `${origin.replace(/^http/, "ws")}/v1/calls/${callUUID}/connect`,
      media_transport: mediaTransport,
    };
  }

  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  const response = await stub.fetch("https://commands.internal/enqueue", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(command),
  });
  const result = await response.json();
  await recordDashboardEvent(env, {
    type: value.type === "dial" ? "call" : "sms",
    device_id: authenticated.device.device_id,
    status: "queued",
    channel: "relay",
    environment: authenticated.device.environment,
  });
  return jsonResponse(response.status, { ...result, ...(call ? { call } : {}) });
}

async function readDeviceCommandResult(request, env) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "device command relay unavailable" });
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  if (!UUID_PATTERN.test(value.command_id || "")) {
    return jsonResponse(400, { error: "invalid command id" });
  }
  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  return stub.fetch(`https://commands.internal/result/${value.command_id.toLowerCase()}`);
}

async function pullDeviceCommands(request, env) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "device command relay unavailable" });
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  return stub.fetch("https://commands.internal/pending", { method: "POST" });
}

async function completeDeviceCommand(request, env) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "device command relay unavailable" });
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  if (!UUID_PATTERN.test(value.command_id || "") ||
      !["completed", "failed"].includes(value.status)) {
    return jsonResponse(400, { error: "invalid command completion" });
  }
  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  return stub.fetch("https://commands.internal/complete", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      command_id: value.command_id.toLowerCase(),
      status: value.status,
      ...(value.result && typeof value.result === "object" ? { result: value.result } : {}),
      ...(value.error ? { error: stringValue(value.error).slice(0, 1_024) } : {}),
    }),
  });
}

async function enqueueCallAction(request, env, pathCallUUID) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "call control relay unavailable" });
  if (!UUID_PATTERN.test(pathCallUUID)) return jsonResponse(400, { error: "invalid call UUID" });
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  const callUUID = pathCallUUID.toLowerCase();
  const call = await readRelayRecord(env, `call:${callUUID}`);
  if (!call) return jsonResponse(404, { error: "call not found" });
  if (call.device_id !== authenticated.device.device_id) {
    return jsonResponse(403, { error: "call belongs to another device" });
  }
  const generation = Number.isSafeInteger(value.generation) && value.generation > 0
    ? value.generation
    : 1;
  const validation = validateCallAction(value, call, callUUID, generation);
  if (validation.status) return jsonResponse(validation.status, { error: validation.error });

  const now = Date.now();
  const callDeadline = Date.parse(call.media_expires_at || call.expires_at || "");
  const expiresAt = Math.min(
    now + 30_000,
    Number.isFinite(callDeadline) ? callDeadline : now + 30_000,
  );
  if (expiresAt <= now) return jsonResponse(410, { error: "call expired" });
  const command = {
    command_id: value.command_id.toLowerCase(),
    type: "call_control",
    action: value.action,
    trace_id: stringValue(value.trace_id).slice(0, 128),
    owner: value.owner,
    issued_at: new Date(now).toISOString(),
    expires_at: new Date(expiresAt).toISOString(),
    call: {
      call_id: call.call_id,
      call_uuid: callUUID,
      generation,
      direction: call.direction || "incoming",
    },
  };
  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  return stub.fetch("https://commands.internal/enqueue", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(command),
  });
}

async function readCallActionResult(request, env, pathCallUUID, commandID) {
  if (!env.COMMANDS) return jsonResponse(503, { error: "call control relay unavailable" });
  if (!UUID_PATTERN.test(pathCallUUID) || !UUID_PATTERN.test(commandID)) {
    return jsonResponse(400, { error: "invalid call control identity" });
  }
  const authorization = request.headers.get("authorization") || "";
  const deviceSecret = authorization.match(/^Bearer\s+(.+)$/i)?.[1] || "";
  const deviceID = request.headers.get("x-airsim-device-id") || "";
  const authenticated = await authenticate({
    device_id: deviceID,
    device_secret: deviceSecret,
  }, env);
  if (authenticated.response) return authenticated.response;
  const callUUID = pathCallUUID.toLowerCase();
  const call = await readRelayRecord(env, `call:${callUUID}`);
  if (!call) return jsonResponse(404, { error: "call not found" });
  if (call.device_id !== authenticated.device.device_id) {
    return jsonResponse(403, { error: "call belongs to another device" });
  }
  const stub = env.COMMANDS.get(env.COMMANDS.idFromName(authenticated.device.device_id));
  return stub.fetch(
    `https://commands.internal/result/${commandID.toLowerCase()}?call_uuid=${callUUID}`,
  );
}

function validateCallAction(value, call, callUUID, generation) {
  if (!UUID_PATTERN.test(value.command_id || "") ||
      !["answer", "reject", "end"].includes(value.action)) {
    return { status: 400, error: "invalid call action" };
  }
  if (stringValue(value.call_id) !== stringValue(call.call_id) ||
      stringValue(value.call_uuid).toLowerCase() !== callUUID) {
    return { status: 409, error: "call identity mismatch" };
  }
  if (generation !== (Number(call.generation) || 1)) {
    return { status: 409, error: "stale call generation" };
  }
  if (value.owner !== "iphone" && value.owner !== "watch") {
    return { status: 400, error: "invalid call owner" };
  }
  if (typeof value.trace_id !== "string" || value.trace_id.length > 128) {
    return { status: 400, error: "invalid trace id" };
  }
  return { status: 0, error: "" };
}

function validateDeviceCommand(value) {
  if (!UUID_PATTERN.test(value.command_id || "") || !COMMAND_TYPES.has(value.type)) {
    return "invalid device command";
  }
  if (value.media_transport !== undefined &&
      (value.type !== "dial" || value.media_transport !== "legacy_pcm")) {
    return "invalid media transport";
  }
  const number = normalizePhoneNumber(value.number);
  if (!number || number.length > 82) return "invalid phone number";
  if (value.type === "dtmf" && (number.length !== 1 || !/^[0-9*#]$/.test(number))) {
    return "invalid DTMF digit";
  }
  if (value.type === "send_sms") {
    if (typeof value.message !== "string" || !value.message.trim() ||
        [...value.message].length > 2_000) return "invalid SMS content";
  }
  return "";
}

function normalizePhoneNumber(value) {
  if (typeof value !== "string") return "";
  const trimmed = value.trim();
  if (!/^[0-9+*# ()-]+$/.test(trimmed)) return "";
  return trimmed.replace(/[ ()-]/g, "");
}

function randomToken(byteCount) {
  const data = new Uint8Array(byteCount);
  crypto.getRandomValues(data);
  return base64url(data);
}

export class DeviceCommandSession {
  constructor(state) {
    this.state = state;
    this.storage = state.storage;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/connect") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return jsonResponse(426, { error: "websocket upgrade required" });
      }
      for (const socket of this.state.getWebSockets("agent")) {
        try { socket.close(4001, "replaced by a newer connection"); } catch {}
      }
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      server.serializeAttachment({ role: "agent" });
      this.state.acceptWebSocket(server, ["agent"]);
      await this.flushPending(server);
      return new Response(null, { status: 101, webSocket: client });
    }
    if (url.pathname === "/enqueue" && request.method === "POST") {
      const command = await request.json();
      const key = `command:${command.command_id}`;
      const existing = await this.storage.get(key);
      if (existing) {
        if (!sameCommandIntent(existing.command, command)) {
          return jsonResponse(409, { error: "command id belongs to another operation" });
        }
        return jsonResponse(202, {
          accepted: true,
          command_id: command.command_id,
          status: existing.status,
          agent_connected: this.state.getWebSockets("agent").length > 0,
          duplicate: true,
          ...(existing.rescue_command_id ? { rescue_command_id: existing.rescue_command_id } : {}),
          ...(existing.result ? { result: existing.result } : {}),
          ...(existing.error ? { error: existing.error } : {}),
        });
      }
      const record = {
        command,
        status: "pending",
        created_at_ms: Date.now(),
        accepted_at: new Date().toISOString(),
        attempts: 0,
        retry_count: 0,
        expires_at_ms: Date.parse(command.expires_at),
        ...(["end", "reject"].includes(command.action)
          ? { rescue_due_at_ms: Date.now() + 8_000 }
          : {}),
      };
      await this.storage.put(key, record);
      const agents = this.state.getWebSockets("agent");
      for (const socket of agents) {
        try {
          socket.send(JSON.stringify(command));
          record.attempts += 1;
        } catch {}
      }
      if (agents.length > 0) {
        record.status = "delivered";
        record.delivered_at = new Date().toISOString();
        await this.storage.put(key, record);
      }
      await this.scheduleAlarm(record);
      return jsonResponse(202, {
        accepted: true,
        command_id: command.command_id,
        status: record.status,
        agent_connected: agents.length > 0,
      });
    }
    const result = url.pathname.match(/^\/result\/([0-9a-f-]+)$/i);
    if (result && request.method === "GET") {
      const record = await this.storage.get(`command:${result[1].toLowerCase()}`);
      if (!record) return jsonResponse(404, { error: "command not found" });
      const requestedCallUUID = url.searchParams.get("call_uuid")?.toLowerCase() || "";
      const recordCallUUID = stringValue(record.command?.call?.call_uuid).toLowerCase();
      if (requestedCallUUID && requestedCallUUID !== recordCallUUID) {
        return jsonResponse(404, { error: "command not found" });
      }
      return jsonResponse(200, {
        command_id: result[1].toLowerCase(),
        status: record.status,
        ...(record.rescue_command_id ? { rescue_command_id: record.rescue_command_id } : {}),
        ...(record.result ? { result: record.result } : {}),
        ...(record.error ? { error: record.error } : {}),
      });
    }
    if (url.pathname === "/pending" && request.method === "POST") {
      const commands = [];
      const records = await this.storage.list({ prefix: "command:" });
      const now = Date.now();
      for (const [key, record] of records) {
        if (commands.length >= 16) break;
        if (!["pending", "delivered"].includes(record?.status)) continue;
        if (!Number.isFinite(record.expires_at_ms) || record.expires_at_ms <= now) {
          record.status = "expired";
          record.error = "云端命令已过期";
          record.completed_at_ms = now;
          record.completed_at = new Date(now).toISOString();
          await this.storage.put(key, record);
          continue;
        }
        record.status = "delivered";
        record.attempts = Number(record.attempts || 0) + 1;
        record.delivered_at = new Date(now).toISOString();
        await this.storage.put(key, record);
        commands.push(record.command);
      }
      await this.scheduleNextPendingAlarm();
      return jsonResponse(200, { commands });
    }
    if (url.pathname === "/complete" && request.method === "POST") {
      const value = await request.json();
      if (!UUID_PATTERN.test(value?.command_id || "") ||
          !["completed", "failed"].includes(value?.status)) {
        return jsonResponse(400, { error: "invalid command completion" });
      }
      const updated = await this.completeCommand(value);
      return updated ? jsonResponse(202, { received: true }) : jsonResponse(404, { error: "command not found" });
    }
    return jsonResponse(404, { error: "not found" });
  }

  async webSocketMessage(socket, message) {
    if (typeof message !== "string" || encoder.encode(message).byteLength > 64 * 1024) return;
    let value;
    try { value = JSON.parse(message); } catch { return; }
    if (!UUID_PATTERN.test(value?.command_id || "") ||
        !["completed", "failed"].includes(value?.status)) return;
    await this.completeCommand(value);
  }

  async completeCommand(value) {
    const key = `command:${value.command_id.toLowerCase()}`;
    const record = await this.storage.get(key);
    if (!record) return false;
    if (["completed", "failed", "expired"].includes(record.status)) return true;
    record.status = value.status;
    record.completed_at_ms = Date.now();
    record.completed_at = new Date().toISOString();
    if (value.status === "completed" && value.result && typeof value.result === "object") {
      record.result = value.result;
      delete record.error;
    } else {
      record.error = stringValue(value.error).slice(0, 1_024) || "Agent command failed";
    }
    await this.storage.put(key, record);
    await this.propagateLinkedCompletion(record);
    await this.scheduleNextPendingAlarm();
    return true;
  }

  async propagateLinkedCompletion(record) {
    const linkedID = record.command?.parent_command_id || record.rescue_command_id;
    if (!linkedID) return;
    const linkedKey = `command:${linkedID}`;
    const linked = await this.storage.get(linkedKey);
    if (!linked || !["pending", "delivered"].includes(linked.status)) return;
    linked.status = record.status;
    linked.completed_at_ms = record.completed_at_ms;
    linked.completed_at = record.completed_at;
    if (record.result) linked.result = record.result;
    if (record.error) linked.error = record.error;
    if (record.command?.parent_command_id) linked.rescue_command_id = record.command.command_id;
    await this.storage.put(linkedKey, linked);
  }

  webSocketClose(socket, code, reason) {
    try { socket.close(code, reason); } catch {}
  }

  webSocketError(socket) {
    try { socket.close(1011, "command relay error"); } catch {}
  }

  async flushPending(socket) {
    const records = await this.storage.list({ prefix: "command:" });
    const now = Date.now();
    for (const [key, record] of records) {
      if (Number.isFinite(record?.expires_at_ms) && record.expires_at_ms <= now) {
        if (!["completed", "failed", "expired"].includes(record.status)) {
          record.status = "expired";
          record.error = "云端命令已过期";
          record.completed_at_ms = now;
          record.completed_at = new Date(now).toISOString();
          await this.storage.put(key, record);
        } else if (now - (record.completed_at_ms || now) > 10 * 60_000) {
          await this.storage.delete(key);
        }
        continue;
      }
      if (!["pending", "delivered"].includes(record?.status)) continue;
      try {
        socket.send(JSON.stringify(record.command));
        record.status = "delivered";
        record.attempts = Number(record.attempts || 0) + 1;
        record.delivered_at = new Date().toISOString();
        await this.storage.put(key, record);
      } catch {}
    }
    await this.scheduleNextPendingAlarm();
  }

  async alarm() {
    const records = await this.storage.list({ prefix: "command:" });
    const now = Date.now();
    const agents = this.state.getWebSockets("agent");
    for (const [key, record] of records) {
      if (!["pending", "delivered"].includes(record?.status)) continue;
      if (!Number.isFinite(record.expires_at_ms) || record.expires_at_ms <= now) {
        record.status = "expired";
        record.error = "云端命令已过期";
        record.completed_at_ms = now;
        record.completed_at = new Date(now).toISOString();
        await this.storage.put(key, record);
        continue;
      }
      if (this.rescueDue(record, now)) {
        await this.createRescue(record, agents, now);
      }
      record.retry_count = Number(record.retry_count || 0) + 1;
      for (const socket of agents) {
        try {
          socket.send(JSON.stringify(record.command));
          record.status = "delivered";
          record.attempts = Number(record.attempts || 0) + 1;
          record.delivered_at = new Date(now).toISOString();
          await this.storage.put(key, record);
        } catch {}
      }
    }
    await this.scheduleNextPendingAlarm();
  }

  rescueDue(record, now) {
    return ["end", "reject"].includes(record.command?.action) &&
      Number.isFinite(record.rescue_due_at_ms) && record.rescue_due_at_ms <= now &&
      !record.rescue_command_id;
  }

  async createRescue(parent, agents, now) {
    const commandID = crypto.randomUUID().toLowerCase();
    const command = {
      ...parent.command,
      command_id: commandID,
      action: "rescue_hangup",
      parent_command_id: parent.command.command_id,
      issued_at: new Date(now).toISOString(),
    };
    const record = {
      command,
      status: "pending",
      created_at_ms: now,
      accepted_at: new Date(now).toISOString(),
      attempts: 0,
      retry_count: 0,
      expires_at_ms: parent.expires_at_ms,
    };
    parent.rescue_command_id = commandID;
    await this.storage.put(`command:${parent.command.command_id}`, parent);
    for (const socket of agents) {
      try {
        socket.send(JSON.stringify(command));
        record.attempts += 1;
      } catch {}
    }
    if (record.attempts > 0) {
      record.status = "delivered";
      record.delivered_at = new Date(now).toISOString();
    }
    await this.storage.put(`command:${commandID}`, record);
  }

  async scheduleAlarm(record) {
    if (!["pending", "delivered"].includes(record?.status) ||
        typeof this.storage.setAlarm !== "function") return;
    const retries = Math.max(0, Number(record.retry_count || 0));
    const delays = [1_000, 2_000, 4_000, 8_000];
    const delay = delays[Math.min(retries, delays.length - 1)];
    const when = Math.min(Date.now() + delay, record.expires_at_ms);
    await this.storage.setAlarm(when);
  }

  async scheduleNextPendingAlarm() {
    if (typeof this.storage.setAlarm !== "function") return;
    const records = await this.storage.list({ prefix: "command:" });
    const pending = [...records.values()].filter((record) =>
      ["pending", "delivered"].includes(record?.status));
    if (pending.length === 0) {
      if (typeof this.storage.deleteAlarm === "function") await this.storage.deleteAlarm();
      return;
    }
    const next = pending.reduce((minimum, record) => {
      const retries = Math.max(0, Number(record.retry_count || 0));
      const delays = [1_000, 2_000, 4_000, 8_000];
      const candidate = Math.min(
        Date.now() + delays[Math.min(retries, delays.length - 1)],
        Number.isFinite(record.rescue_due_at_ms) && !record.rescue_command_id
          ? record.rescue_due_at_ms
          : Number.POSITIVE_INFINITY,
        record.expires_at_ms,
      );
      return Math.min(minimum, candidate);
    }, Number.POSITIVE_INFINITY);
    if (Number.isFinite(next)) await this.storage.setAlarm(next);
  }
}

function sameCommandIntent(left, right) {
  if (left?.type !== right?.type) return false;
  if (left?.type !== "call_control") return true;
  return left.action === right.action &&
    left.owner === right.owner &&
    stringValue(left.call?.call_id) === stringValue(right.call?.call_id) &&
    stringValue(left.call?.call_uuid).toLowerCase() === stringValue(right.call?.call_uuid).toLowerCase() &&
    (Number(left.call?.generation) || 1) === (Number(right.call?.generation) || 1);
}

async function connectCallMedia(request, env, callUUID) {
  if (!UUID_PATTERN.test(callUUID)) return jsonResponse(400, { error: "invalid call UUID" });
  if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    return jsonResponse(426, { error: "websocket upgrade required" });
  }
  const url = new URL(request.url);
  const role = url.searchParams.get("role") || "";
  if (role !== "agent" && !MEDIA_CLIENT_ROLES.has(role)) {
    return jsonResponse(400, { error: "invalid media role" });
  }
  const token = url.searchParams.get("token") || "";
  const call = await readRelayRecord(env, `call:${callUUID}`);
  if (!call || !constantTimeEqual(call.secret_hash, await sha256Hex(token))) {
    return jsonResponse(401, { error: "call authentication failed" });
  }
  const expiresAt = Date.parse(call.media_expires_at || call.expires_at);
  if (!Number.isFinite(expiresAt) || expiresAt < Date.now() - 5_000) {
    return jsonResponse(410, { error: "call expired" });
  }
  if (!env.MEDIA) return jsonResponse(503, { error: "media relay unavailable" });

  const id = env.MEDIA.idFromName(callUUID.toLowerCase());
  const stub = env.MEDIA.get(id);
  const headers = new Headers(request.headers);
  headers.set("x-airsim-role", role);
  headers.set("x-airsim-call-id", call.call_id || "");
  headers.set("x-airsim-call-uuid", callUUID.toLowerCase());
  headers.set("x-airsim-generation", String(call.generation || 1));
  const forwarded = new Request("https://media.internal/session", { headers });
  return stub.fetch(forwarded);
}

export class CallMediaSession {
  constructor(state, env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request) {
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return jsonResponse(426, { error: "websocket upgrade required" });
    }
    const role = request.headers.get("x-airsim-role");
    if (role !== "agent" && !MEDIA_CLIENT_ROLES.has(role)) {
      return jsonResponse(400, { error: "invalid media role" });
    }
    let inheritsOwnership = false;
    let inheritedPendingControl = "";
    for (const existing of this.state.getWebSockets(role)) {
      const attachment = existing.deserializeAttachment() || {};
      inheritsOwnership ||= attachment.owner === true;
      if (typeof attachment.pendingControl === "string" && attachment.pendingControl) {
        inheritedPendingControl = attachment.pendingControl;
      }
      existing.close(4001, "replaced by a newer connection");
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.serializeAttachment({
      role,
      owner: inheritsOwnership,
      pendingControl: inheritedPendingControl,
      callID: request.headers.get("x-airsim-call-id") || "",
      callUUID: request.headers.get("x-airsim-call-uuid") || "",
      generation: Number(request.headers.get("x-airsim-generation")) || 1,
    });
    this.state.acceptWebSocket(server, [role]);
    if (role === "agent") this.flushPendingControls(server);
    this.broadcastStatus("peer_connected", role);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(socket, message) {
    const attachment = socket.deserializeAttachment() || {};
    const role = attachment.role;
    if (role !== "agent" && !MEDIA_CLIENT_ROLES.has(role)) {
      socket.close(1008, "missing media role");
      return;
    }
    const size = typeof message === "string"
      ? encoder.encode(message).byteLength
      : message.byteLength;
    if (size <= 0 || size > 64 * 1024) {
      socket.close(1009, "media frame too large");
      return;
    }
    if (role !== "agent" && !this.acceptClientMessage(socket, role, message)) return;
    const outbound = role === "agent" ? message : bindMediaOwner(message, role);
    const control = role === "agent" ? null : callControlMetadata(outbound);
    if (control) this.logControl("received", role, control);
    const peers = this.mediaPeers(role);
    if (role !== "agent" && peers.length === 0 && this.isControlMessage(outbound)) {
      const current = socket.deserializeAttachment() || {};
      socket.serializeAttachment({ ...current, role, pendingControl: outbound });
      this.logControl("queued", role, control);
      try { socket.send(callControlReceipt("action_queued", control)); } catch {}
      return;
    }
    for (const peer of peers) {
      try { peer.send(outbound); } catch {}
    }
    if (role !== "agent" && peers.length > 0 && this.isControlMessage(outbound)) {
      const current = socket.deserializeAttachment() || {};
      socket.serializeAttachment({ ...current, role, pendingControl: "" });
      this.logControl("forwarded", role, control);
      try { socket.send(callControlReceipt("action_forwarded", control)); } catch {}
    }
  }

  acceptClientMessage(socket, role, message) {
    const owner = this.ownerRole();
    if (owner && owner !== role) {
      try { socket.send(JSON.stringify({ status: "ownership_lost", owner })); } catch {}
      return false;
    }
    if (typeof message !== "string") return owner === role;
    let action = "";
    try { action = JSON.parse(message)?.action || ""; } catch { return false; }
    if (action === "answer") {
      if (!owner) this.claimOwner(socket, role);
      return true;
    }
    // 未接听时任一系统界面都可以拒接；接通后只有媒体所有者可以挂断。
    if (action === "reject") return !owner || owner === role;
    if (action === "end") return owner === role;
    return owner === role;
  }

  claimOwner(socket, role) {
    const current = socket.deserializeAttachment() || {};
    socket.serializeAttachment({ ...current, role, owner: true });
    for (const peer of this.state.getWebSockets()) {
      if (peer === socket) continue;
      const attachment = peer.deserializeAttachment() || {};
      if (!MEDIA_CLIENT_ROLES.has(attachment.role)) continue;
      try { peer.send(JSON.stringify({ status: "ownership_lost", owner: role })); } catch {}
      try { peer.close(4002, "answered on another device"); } catch {}
    }
    this.broadcastStatus("owner_claimed", role);
  }

  isControlMessage(message) {
    if (typeof message !== "string") return false;
    try { return ["answer", "reject", "end"].includes(JSON.parse(message)?.action); }
    catch { return false; }
  }

  flushPendingControls(agentSocket) {
    for (const role of MEDIA_CLIENT_ROLES) {
      for (const client of this.state.getWebSockets(role)) {
        const attachment = client.deserializeAttachment() || {};
        if (typeof attachment.pendingControl !== "string" || !attachment.pendingControl) continue;
        try {
          agentSocket.send(attachment.pendingControl);
          client.serializeAttachment({ ...attachment, pendingControl: "" });
          const control = callControlMetadata(attachment.pendingControl);
          this.logControl("forwarded_after_reconnect", attachment.role, control);
          client.send(callControlReceipt("action_forwarded", control));
        } catch {}
      }
    }
  }

  ownerRole() {
    for (const socket of this.state.getWebSockets()) {
      const attachment = socket.deserializeAttachment() || {};
      if (attachment.owner === true && MEDIA_CLIENT_ROLES.has(attachment.role)) {
        return attachment.role;
      }
    }
    return "";
  }

  mediaPeers(role) {
    if (role !== "agent") return this.state.getWebSockets("agent");
    const owner = this.ownerRole();
    if (owner) return this.state.getWebSockets(owner);
    return [...this.state.getWebSockets("watch"), ...this.state.getWebSockets("iphone")];
  }

  webSocketClose(socket, code, reason) {
    const role = socket.deserializeAttachment()?.role || "unknown";
    try { socket.close(code, reason); } catch {}
    this.broadcastStatus("peer_disconnected", role);
  }

  logControl(stage, role, control) {
    if (!control) return;
    console.log(JSON.stringify({
      event: "call_control_trace", stage, role,
      action: control.action, call_id: control.call_id, call_uuid: control.call_uuid,
      generation: control.generation, command_id: control.command_id, trace_id: control.trace_id,
    }));
  }

  webSocketError(socket) {
    const role = socket.deserializeAttachment()?.role || "unknown";
    try { socket.close(1011, "media relay error"); } catch {}
    this.broadcastStatus("peer_disconnected", role);
  }

  broadcastStatus(event, role) {
    const message = JSON.stringify({ event, role });
    for (const peer of this.state.getWebSockets()) {
      try { peer.send(message); } catch {}
    }
  }
}

export function bindMediaOwner(message, role) {
  if (typeof message !== "string" || !MEDIA_CLIENT_ROLES.has(role)) return message;
  try {
    const value = JSON.parse(message);
    if (!["answer", "reject", "end"].includes(value?.action)) return message;
    return JSON.stringify({ ...value, owner: role });
  } catch {
    return message;
  }
}

export function callControlMetadata(message) {
  if (typeof message !== "string") return null;
  try {
    const value = JSON.parse(message);
    if (!["answer", "reject", "end"].includes(value?.action)) return null;
    return {
      action: stringValue(value.action),
      call_id: stringValue(value.call_id),
      call_uuid: stringValue(value.call_uuid).toLowerCase(),
      generation: Number.isSafeInteger(value.generation) && value.generation > 0 ? value.generation : 1,
      command_id: stringValue(value.command_id).toLowerCase(),
      trace_id: stringValue(value.trace_id).slice(0, 128),
    };
  } catch {
    return null;
  }
}

function callControlReceipt(status, control) {
  return JSON.stringify({ status, ...(control || {}) });
}

async function registerDevice(request, env) {
  const device = await readJSON(request);
  const validationError = validateRegistration(device, env.ALLOWED_BUNDLE_ID);
  if (validationError) return jsonResponse(400, { error: validationError });

  const secretHash = await sha256Hex(device.device_secret);
  const existing = await readDeviceRecord(env, device.device_id.trim());
  if (existing && !constantTimeEqual(existing.secret_hash, secretHash)) {
    return jsonResponse(401, { error: "device authentication failed" });
  }

  const record = {
    device_id: device.device_id.trim(),
    secret_hash: secretHash,
    voip_token: (device.voip_token || "").toLowerCase(),
    alert_token: (device.alert_token || "").toLowerCase(),
    watch_voip_token: (device.watch_voip_token || "").toLowerCase(),
    watch_bundle_id: stringValue(device.watch_bundle_id),
    live_activity_push_to_start_token: (device.live_activity_push_to_start_token || "").toLowerCase(),
    bundle_id: device.bundle_id,
    environment: device.environment,
    registered_at: new Date().toISOString(),
    media_transport_requested: MEDIA_TRANSPORTS.has(device.media_transport)
      ? device.media_transport : (existing?.media_transport_requested || "legacy_pcm"),
    app_media_capabilities: normalizedMediaCapabilities(
      device.app_media_capabilities ?? existing?.app_media_capabilities,
    ),
    agent_media_capabilities: normalizedMediaCapabilities(
      device.agent_media_capabilities ?? existing?.agent_media_capabilities,
    ),
    force_legacy_pcm: device.force_legacy_pcm === true,
  };
  record.media_transport = assignedMediaTransport(record, env);
  await writeDeviceRecord(env, record.device_id, record);
  await recordDashboardEvent(env, {
    type: "registration", device_id: record.device_id, status: "delivered",
    channel: "relay", environment: record.environment,
  });
  // Keep the public response shape stable for older App/Agent builds. The
  // negotiated transport lives in the device record and each call descriptor.
  return jsonResponse(200, { registered: true });
}

async function registerLiveActivity(request, env) {
  const value = await readJSON(request);
  const authenticated = await authenticate(value, env);
  if (authenticated.response) return authenticated.response;
  if (!nonEmpty(value.activity_id) || value.activity_id.length > 128 ||
      typeof value.call_id !== "string" || value.call_id.length > 128 ||
      !TOKEN_PATTERN.test(value.update_token || "")) {
    return jsonResponse(400, { error: "invalid live activity registration" });
  }
  await writeRelayState(
    env,
    `liveactivity:current:${authenticated.device.device_id}`,
    JSON.stringify({
      activity_id: value.activity_id,
      call_id: value.call_id,
      update_token: value.update_token.toLowerCase(),
      updated_at: new Date().toISOString(),
    }),
    8 * 60 * 60,
  );
  return jsonResponse(200, { registered: true });
}

async function receiveCall(request, env) {
  const call = await readJSON(request);
  const authenticated = await authenticate(call, env);
  if (authenticated.response) return authenticated.response;
  if (!authenticated.device.voip_token && !authenticated.device.watch_voip_token) {
    return jsonResponse(409, { error: "VoIP token unavailable" });
  }

  const now = Date.now();
  const expiresAt = Date.parse(call.expires_at);
  const callSecretSupplied = typeof call.call_secret === "string" && call.call_secret.length > 0;
  const mediaReady = typeof call.call_secret === "string" &&
    call.call_secret.length >= 24 && call.call_secret.length <= 256;
  const generation = Number.isSafeInteger(call.generation) && call.generation > 0
    ? call.generation
    : 1;
  const mediaTransport = assignedMediaTransport(authenticated.device, env, call.media_transport);
  if (call.event !== "incoming_call" || !nonEmpty(call.call_id) ||
      !UUID_PATTERN.test(call.call_uuid || "") || !Number.isFinite(expiresAt) ||
      (callSecretSupplied && !mediaReady) ||
      expiresAt <= now - 5_000 || expiresAt > now + 120_000) {
    return jsonResponse(400, { error: "invalid incoming call" });
  }

  const lifecycleKey = `call-lifecycle:${authenticated.device.device_id}`;
  const lifecycle = applyCallLifecycle(await readRelayRecord(env, lifecycleKey), {
    call_id: call.call_id.trim(),
    call_uuid: call.call_uuid.toLowerCase(),
    generation,
    phase: "ringing",
    source: "agent",
    timestamp: nonEmpty(call.issued_at) && Number.isFinite(Date.parse(call.issued_at))
      ? call.issued_at : new Date(now).toISOString(),
    trace_id: nonEmpty(call.trace_id) ? call.trace_id : null,
    failure: null,
  });
  if (!lifecycle.accepted) {
    return jsonResponse(409, { accepted: false, reason: lifecycle.reason, lifecycle: lifecycle.snapshot });
  }
  await writeRelayState(env, lifecycleKey, JSON.stringify(lifecycle.snapshot), 5 * 60 * 60);

  const voipDedupeKey = `dedupe:call:voip:${authenticated.device.device_id}:${call.call_uuid}`;
  const watchDedupeKey = `dedupe:call:watch:${authenticated.device.device_id}:${call.call_uuid}`;
  const alertDedupeKey = `dedupe:call:alert:${authenticated.device.device_id}:${call.call_uuid}`;
  const activityDedupeKey = `dedupe:call:liveactivity:${authenticated.device.device_id}:${call.call_uuid}`;
  const voipDuplicate = !authenticated.device.voip_token ||
    Boolean(await readRelayState(env, voipDedupeKey));
  const watchDuplicate = !mediaReady || !authenticated.device.watch_voip_token ||
    Boolean(await readRelayState(env, watchDedupeKey));
  const alertDuplicate = !authenticated.device.alert_token ||
    Boolean(await readRelayState(env, alertDedupeKey));
  const currentActivity = await readRelayRecord(
    env,
    `liveactivity:current:${authenticated.device.device_id}`,
  );
  const activityToken = currentActivity?.update_token ||
    authenticated.device.live_activity_push_to_start_token || "";
  const activityDuplicate = !activityToken || Boolean(await readRelayState(env, activityDedupeKey));
  let activityPushed = false;

  const mediaURL = `${new URL(request.url).origin.replace(/^http/, "ws")}/v1/calls/${call.call_uuid}/connect`;
  if (mediaReady) {
    await writeRelayState(env, `call:${call.call_uuid}`, JSON.stringify({
      device_id: authenticated.device.device_id,
      call_id: call.call_id,
      call_uuid: call.call_uuid.toLowerCase(),
      generation,
      direction: "incoming",
      secret_hash: await sha256Hex(call.call_secret),
      expires_at: call.expires_at,
      media_expires_at: new Date(now + 4 * 60 * 60 * 1000).toISOString(),
      media_transport: mediaTransport,
    }), 5 * 60 * 60);
  }

  const voipPayload = {
    aps: { "content-available": 1 },
    event: "incoming_call",
    call_id: call.call_id,
    call_uuid: call.call_uuid,
    generation,
    number: stringValue(call.number),
    caller_name: stringValue(call.caller_name),
    issued_at: call.issued_at,
    expires_at: call.expires_at,
    ...(mediaReady ? { call_secret: call.call_secret, media_url: mediaURL } : {}),
    media_transport: mediaTransport,
  };

  try {
    if (!voipDuplicate) {
      await sendAPNs(env, authenticated.device, authenticated.device.voip_token, {
        topic: `${authenticated.device.bundle_id}.voip`,
        pushType: "voip",
        priority: "10",
        expiration: Math.floor(expiresAt / 1000),
        collapseID: call.call_uuid,
        payload: voipPayload,
      });
      await writeRelayState(env, voipDedupeKey, "1", 180);
    }

    if (!watchDuplicate) {
      await sendAPNs(env, authenticated.device, authenticated.device.watch_voip_token, {
        topic: `${authenticated.device.watch_bundle_id}.voip`,
        pushType: "voip",
        priority: "10",
        expiration: Math.floor(expiresAt / 1000),
        collapseID: call.call_uuid,
        payload: voipPayload,
      });
      await writeRelayState(env, watchDedupeKey, "1", 180);
    }

    if (!alertDuplicate) {
      const displayName = stringValue(call.caller_name) || stringValue(call.number) || "未知号码";
      const alertBody = stringValue(call.caller_name) && stringValue(call.number)
        ? stringValue(call.number)
        : "AirSIM 语音来电";
      const alertPayload = {
        aps: {
          alert: { title: displayName, body: alertBody },
          sound: "default",
          category: "AIRSIM_INCOMING_CALL_MIRROR",
          "thread-id": `airsim-call-${call.call_uuid}`,
          "interruption-level": "time-sensitive",
        },
        event: "incoming_call_mirror",
        call_id: call.call_id,
        call_uuid: call.call_uuid,
        number: stringValue(call.number),
        caller_name: stringValue(call.caller_name),
        issued_at: call.issued_at,
        expires_at: call.expires_at,
      };
      await sendAPNs(env, authenticated.device, authenticated.device.alert_token, {
        topic: authenticated.device.bundle_id,
        pushType: "alert",
        priority: "10",
        expiration: Math.floor(expiresAt / 1000),
        collapseID: call.call_uuid,
        payload: alertPayload,
      });
      await writeRelayState(env, alertDedupeKey, "1", 180);
    }

    if (!activityDuplicate) {
      const isUpdate = Boolean(currentActivity?.update_token);
      try {
        await sendAPNs(env, authenticated.device, activityToken, {
          topic: `${authenticated.device.bundle_id}.push-type.liveactivity`,
          pushType: "liveactivity",
          priority: "10",
          expiration: Math.floor(expiresAt / 1000),
          collapseID: call.call_uuid,
          payload: liveActivityPayload({
            event: isUpdate ? "update" : "start",
            callID: call.call_id,
            number: stringValue(call.number),
            displayName: stringValue(call.caller_name) || stringValue(call.number) || "未知号码",
            phase: "incoming",
            startedAt: call.issued_at,
          }),
        });
        await writeRelayState(env, activityDedupeKey, "1", 180);
        activityPushed = true;
      } catch (error) {
        // Live Activity 是来电展示增强，token 失效不能反向破坏已经成功的 VoIP/CallKit。
        if (isUpdate) {
          await deleteRelayState(env, `liveactivity:current:${authenticated.device.device_id}`);
        }
        console.error("APNs Live Activity delivery failed", safeError(error));
      }
    }

    if (voipDuplicate && watchDuplicate && alertDuplicate && activityDuplicate) {
      return jsonResponse(202, { duplicate: true });
    }
    await recordDashboardEvent(env, {
      type: "call", device_id: authenticated.device.device_id, status: "delivered",
      channel: !voipDuplicate ? "iphone" : !watchDuplicate ? "watch" : !alertDuplicate ? "alert" : "live_activity",
      environment: authenticated.device.environment,
    });
    return jsonResponse(202, {
      pushed: true,
      voip_pushed: !voipDuplicate,
      watch_pushed: !watchDuplicate,
      alert_pushed: !alertDuplicate,
      live_activity_pushed: activityPushed,
    });
  } catch (error) {
    await recordDashboardEvent(env, {
      type: "call", device_id: authenticated.device.device_id, status: "failed",
      channel: "relay", environment: authenticated.device.environment,
    });
    console.error("APNs incoming call delivery failed", safeError(error));
    return jsonResponse(502, { error: "APNs delivery failed" });
  }
}

async function receiveSMS(request, env) {
  const message = await readJSON(request);
  const authenticated = await authenticate(message, env);
  if (authenticated.response) return authenticated.response;
  if (!authenticated.device.alert_token) {
    return jsonResponse(409, { error: "alert token unavailable" });
  }

  const timestamp = Date.parse(message.timestamp);
  const now = Date.now();
  if (message.event !== "incoming_sms" || !nonEmpty(message.delivery_id) ||
      !nonEmpty(message.sender) || !nonEmpty(message.content) || !Number.isFinite(timestamp) ||
      timestamp > now + 300_000 || timestamp < now - 7 * 24 * 60 * 60 * 1000) {
    return jsonResponse(400, { error: "invalid incoming SMS" });
  }

  const dedupeKey = `dedupe:sms:${authenticated.device.device_id}:${message.delivery_id}`;
  if (await readRelayState(env, dedupeKey)) {
    return jsonResponse(202, { duplicate: true });
  }
  await writeRelayState(env, dedupeKey, "1", 7 * 24 * 60 * 60);

  const [content, truncated] = truncateCodePoints(message.content, 700);
  const payload = {
    aps: {
      alert: { title: message.sender, body: content },
      sound: "default",
      "thread-id": `airsim-sms-${message.sender}`.slice(0, 64),
      "content-available": 1,
    },
    event: "incoming_sms",
    delivery_id: message.delivery_id,
    sender: message.sender,
    content,
    content_truncated: truncated,
    code: stringValue(message.code),
    timestamp: message.timestamp,
  };
  try {
    await sendAPNs(env, authenticated.device, authenticated.device.alert_token, {
      topic: authenticated.device.bundle_id,
      pushType: "alert",
      priority: "10",
      expiration: Math.floor(now / 1000) + 24 * 60 * 60,
      collapseID: message.delivery_id,
      payload,
    });
    await recordDashboardEvent(env, {
      type: "sms", device_id: authenticated.device.device_id, status: "delivered",
      channel: "alert", environment: authenticated.device.environment,
    });
    return jsonResponse(202, { pushed: true });
  } catch (error) {
    await deleteRelayState(env, dedupeKey);
    await recordDashboardEvent(env, {
      type: "sms", device_id: authenticated.device.device_id, status: "failed",
      channel: "alert", environment: authenticated.device.environment,
    });
    console.error("APNs SMS delivery failed", safeError(error));
    return jsonResponse(502, { error: "APNs delivery failed" });
  }
}

async function receiveAgentHeartbeat(request, env) {
  const heartbeat = await readJSON(request);
  const authenticated = await authenticate(heartbeat, env);
  if (authenticated.response) return authenticated.response;
  if (heartbeat.event !== "agent_heartbeat" ||
      !["registered", "searching", "denied", "unregistered"].includes(heartbeat.cellular_state) ||
      typeof heartbeat.at_ok !== "boolean") {
    return jsonResponse(400, { error: "invalid agent heartbeat" });
  }
  const agentID = stringValue(heartbeat.agent_id) || "legacy";
  const record = {
    received_at_ms: Date.now(),
    agent_id: agentID,
    ...(nonEmpty(heartbeat.agent_kind) ? { agent_kind: heartbeat.agent_kind.trim() } : {}),
    ...(nonEmpty(heartbeat.device_name) ? { device_name: heartbeat.device_name.trim() } : {}),
    ...(nonEmpty(heartbeat.manufacturer) ? { manufacturer: heartbeat.manufacturer.trim() } : {}),
    ...(nonEmpty(heartbeat.model) ? { model: heartbeat.model.trim() } : {}),
    ...(nonEmpty(heartbeat.phone_number) ? { phone_number: heartbeat.phone_number.trim() } : {}),
    agent_version: stringValue(heartbeat.agent_version),
    at_ok: heartbeat.at_ok,
    cellular_state: heartbeat.cellular_state,
    cellular_registration: stringValue(heartbeat.cellular_registration),
    cellular_recovery: stringValue(heartbeat.cellular_recovery),
    ecm_carrier: stringValue(heartbeat.ecm_carrier),
    ...(Number.isFinite(heartbeat.signal_dbm) ? { signal_dbm: heartbeat.signal_dbm } : {}),
  };
  await writeAgentHeartbeat(env, authenticated.device.device_id, agentID, record);
  return jsonResponse(202, { received: true });
}

async function receiveDeviceStatus(request, env) {
  const query = await readJSON(request);
  const authenticated = await authenticate(query, env);
  if (authenticated.response) return authenticated.response;
  const now = Date.now();
  const heartbeats = await readAgentHeartbeats(env, authenticated.device.device_id);
  const agents = heartbeats
    .filter((item) => item && Number.isFinite(item.received_at_ms))
    .sort((left, right) => right.received_at_ms - left.received_at_ms)
    .map((item) => {
      const { received_at_ms: receivedAtMS, ...status } = item;
      return { ...status, cloud_online: now - receivedAtMS <= 90_000 };
    });
  const heartbeat = heartbeats
    .filter((item) => item && Number.isFinite(item.received_at_ms) && now - item.received_at_ms <= 90_000)
    .sort((left, right) => right.received_at_ms - left.received_at_ms)[0];
  if (!heartbeat) {
    return jsonResponse(200, { cloud_online: false, agents });
  }
  const { received_at_ms: _, ...publicStatus } = heartbeat;
  return jsonResponse(200, {
    cloud_online: true,
    ...publicStatus,
    active_agent_id: publicStatus.agent_id || "legacy",
    agents,
  });
}

async function receiveCallOwner(request, env) {
  const event = await readJSON(request);
  const authenticated = await authenticate(event, env);
  if (authenticated.response) return authenticated.response;
  if (!authenticated.device.alert_token) {
    return jsonResponse(409, { error: "alert token unavailable" });
  }
  if (event.event !== "call_owner" || !nonEmpty(event.call_id) ||
      !UUID_PATTERN.test(event.call_uuid || "") || !MEDIA_CLIENT_ROLES.has(event.owner) ||
      (event.phase !== "active" && event.phase !== "ended")) {
    return jsonResponse(400, { error: "invalid call ownership event" });
  }
  const dedupeKey = `dedupe:owner:${authenticated.device.device_id}:${event.call_uuid}:${event.phase}`;
  if (await readRelayState(env, dedupeKey)) return jsonResponse(202, { duplicate: true });

  const payload = {
    aps: { "content-available": 1 },
    event: "call_owner",
    call_id: event.call_id,
    call_uuid: event.call_uuid,
    owner: event.owner,
    phase: event.phase,
  };
  try {
    await sendAPNs(env, authenticated.device, authenticated.device.alert_token, {
      topic: authenticated.device.bundle_id,
      pushType: "background",
      priority: "5",
      expiration: Math.floor(Date.now() / 1000) + 120,
      collapseID: `${event.call_uuid}-${event.phase}`,
      payload,
    });
    await writeRelayState(env, dedupeKey, "1", 180);
    await recordDashboardEvent(env, {
      type: "call_owner", device_id: authenticated.device.device_id, status: "delivered",
      channel: event.owner === "watch" ? "watch" : "iphone",
      environment: authenticated.device.environment,
    });
    const currentActivity = await readRelayRecord(
      env,
      `liveactivity:current:${authenticated.device.device_id}`,
    );
    if (currentActivity?.update_token) {
      await sendAPNs(env, authenticated.device, currentActivity.update_token, {
        topic: `${authenticated.device.bundle_id}.push-type.liveactivity`,
        pushType: "liveactivity",
        priority: "10",
        expiration: Math.floor(Date.now() / 1000) + 120,
        collapseID: `${event.call_uuid}-${event.phase}`,
        payload: liveActivityPayload({
          event: "update",
          callID: event.phase === "ended" ? "" : event.call_id,
          number: "",
          displayName: event.phase === "ended" ? "公网中继已连接" : "通话中",
          phase: event.phase === "ended" ? "cloud_standby" : "active",
          startedAt: new Date().toISOString(),
        }),
      });
    }
    return jsonResponse(202, { pushed: true });
  } catch (error) {
    console.error("APNs call ownership delivery failed", safeError(error));
    return jsonResponse(502, { error: "APNs delivery failed" });
  }
}

async function receiveCallState(request, env) {
  const event = await readJSON(request);
  const authenticated = await authenticate(event, env);
  if (authenticated.response) return authenticated.response;
  const generation = Number.isInteger(event.generation) && event.generation > 0
    ? event.generation : 1;
  const source = nonEmpty(event.source) ? event.source.trim().toLowerCase() : "agent";
  const timestamp = nonEmpty(event.timestamp) ? event.timestamp : new Date().toISOString();
  if (event.event !== "call_state" || !nonEmpty(event.call_id) ||
      !UUID_PATTERN.test(event.call_uuid || "") ||
      !CALL_LIFECYCLE_PHASES.has(event.phase) || !CALL_LIFECYCLE_SOURCES.has(source) ||
      !Number.isFinite(Date.parse(timestamp))) {
    return jsonResponse(400, { error: "invalid call state event" });
  }
  const lifecycleKey = `call-lifecycle:${authenticated.device.device_id}`;
  const currentLifecycle = await readRelayRecord(env, lifecycleKey);
  const transition = applyCallLifecycle(currentLifecycle, {
    call_id: event.call_id.trim(),
    call_uuid: event.call_uuid.toLowerCase(),
    generation,
    phase: event.phase,
    source,
    timestamp,
    trace_id: nonEmpty(event.trace_id) ? event.trace_id : null,
    failure: nonEmpty(event.failure) ? event.failure : null,
  });
  if (!transition.accepted) {
    return jsonResponse(409, { accepted: false, reason: transition.reason, lifecycle: transition.snapshot });
  }
  await writeRelayState(env, lifecycleKey, JSON.stringify(transition.snapshot), 5 * 60 * 60);
  const dedupeKey = `dedupe:call-state:${authenticated.device.device_id}:${event.call_uuid}:${generation}:${event.phase}`;
  if (await readRelayState(env, dedupeKey)) return jsonResponse(202, { duplicate: true });
  const currentActivity = await readRelayRecord(
    env,
    `liveactivity:current:${authenticated.device.device_id}`,
  );
  if (!currentActivity?.update_token) {
    await writeRelayState(env, dedupeKey, "1", 180);
    return jsonResponse(202, { accepted: true, lifecycle: transition.snapshot, live_activity_unavailable: true });
  }
  try {
    const activityPhase = event.phase === "ringing"
      ? "incoming"
      : (["ended", "failed"].includes(event.phase) ? "cloud_standby" : "active");
    await sendAPNs(env, authenticated.device, currentActivity.update_token, {
      topic: `${authenticated.device.bundle_id}.push-type.liveactivity`,
      pushType: "liveactivity",
      priority: "10",
      expiration: Math.floor(Date.now() / 1000) + 120,
      collapseID: `${event.call_uuid}-${event.phase}`,
      payload: liveActivityPayload({
        event: "update",
        callID: ["ended", "failed"].includes(event.phase) ? "" : event.call_id,
        number: "",
        displayName: ["ended", "failed"].includes(event.phase) ? "公网中继已连接" : "通话中",
        phase: activityPhase,
        startedAt: timestamp,
      }),
    });
    await writeRelayState(env, dedupeKey, "1", 180);
    return jsonResponse(202, { pushed: true });
  } catch (error) {
    console.error("APNs call state delivery failed", safeError(error));
    return jsonResponse(502, { error: "APNs delivery failed" });
  }
}

const CALL_LIFECYCLE_PHASES = new Set([
  "idle", "ringing", "connecting", "active", "ending", "ended", "failed",
]);
const CALL_LIFECYCLE_SOURCES = new Set(["app", "callkit", "agent", "relay"]);

export function applyCallLifecycle(current, candidate) {
  const generation = Number(candidate?.generation || 0);
  if (!candidate || !nonEmpty(candidate.call_id) ||
      !UUID_PATTERN.test(candidate.call_uuid || "") || generation <= 0 ||
      !CALL_LIFECYCLE_PHASES.has(candidate.phase) || candidate.phase === "idle") {
    return { accepted: false, reason: "invalid_event", snapshot: current ?? null };
  }
  if (!current) return { accepted: true, snapshot: { ...candidate, generation } };
  const currentGeneration = Number(current.generation || 1);
  const sameIdentity = current.call_id === candidate.call_id &&
    current.call_uuid.toLowerCase() === candidate.call_uuid.toLowerCase();
  if (!sameIdentity) {
    if (!["ended", "failed"].includes(current.phase) ||
        !["ringing", "connecting"].includes(candidate.phase)) {
      return { accepted: false, reason: "identity_mismatch", snapshot: current };
    }
    return { accepted: true, snapshot: { ...candidate, generation } };
  }
  if (generation < currentGeneration) {
    return { accepted: false, reason: "stale_generation", snapshot: current };
  }
  if (generation > currentGeneration) {
    return { accepted: true, snapshot: { ...candidate, generation } };
  }
  if (Date.parse(candidate.timestamp) < Date.parse(current.timestamp)) {
    return { accepted: false, reason: "stale_timestamp", snapshot: current };
  }
  const allowed = {
    idle: ["ringing", "connecting", "active", "failed"],
    ringing: ["ringing", "connecting", "active", "ending", "ended", "failed"],
    connecting: ["connecting", "active", "ending", "ended", "failed"],
    active: ["active", "ending", "ended", "failed"],
    ending: ["ending", "ended", "failed"],
    ended: ["ended"],
    failed: ["failed"],
  };
  if (!(allowed[current.phase] || []).includes(candidate.phase)) {
    return { accepted: false, reason: "illegal_transition", snapshot: current };
  }
  return { accepted: true, snapshot: { ...candidate, generation } };
}

function normalizedMediaCapabilities(value) {
  const capabilities = Array.isArray(value) ? value : ["legacy_pcm"];
  const normalized = [...new Set(capabilities.filter((item) => MEDIA_TRANSPORTS.has(item)))];
  return normalized.includes("legacy_pcm") ? normalized : ["legacy_pcm", ...normalized];
}

function stableMediaRolloutBucket(deviceID) {
  let hash = 2166136261;
  for (const byte of encoder.encode(String(deviceID || ""))) {
    hash ^= byte;
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash % 100;
}

export function selectMediaTransport({
  deviceID,
  requested = "legacy_pcm",
  appCapabilities = ["legacy_pcm"],
  agentCapabilities = ["legacy_pcm"],
  relayCapabilities = ["legacy_pcm", "webrtc"],
  rolloutPercent = 0,
  forceLegacy = false,
} = {}) {
  if (forceLegacy || requested !== "webrtc") return "legacy_pcm";
  const app = normalizedMediaCapabilities(appCapabilities);
  const agent = normalizedMediaCapabilities(agentCapabilities);
  const relay = normalizedMediaCapabilities(relayCapabilities);
  if (!app.includes("webrtc") || !agent.includes("webrtc") || !relay.includes("webrtc")) {
    return "legacy_pcm";
  }
  const percentage = Math.max(0, Math.min(100, Number(rolloutPercent) || 0));
  return stableMediaRolloutBucket(deviceID) < percentage ? "webrtc" : "legacy_pcm";
}

function assignedMediaTransport(device, env, requestedOverride = "") {
  const relayCapabilities = env.WEBRTC_TRANSPORT_READY === "true"
    ? ["legacy_pcm", "webrtc"]
    : ["legacy_pcm"];
  return selectMediaTransport({
    deviceID: device.device_id,
    requested: MEDIA_TRANSPORTS.has(requestedOverride)
      ? requestedOverride
      : device.media_transport_requested,
    appCapabilities: device.app_media_capabilities,
    agentCapabilities: device.agent_media_capabilities,
    relayCapabilities,
    rolloutPercent: env.WEBRTC_ROLLOUT_PERCENT,
    forceLegacy: device.force_legacy_pcm === true,
  });
}

function liveActivityPayload({ event, callID, number, displayName, phase, startedAt }) {
  const parsedStartedAt = Date.parse(startedAt);
  const contentState = {
    callID,
    number,
    displayName,
    phase,
    // Swift Codable 的 Date 默认使用 2001-01-01 reference date 秒数。
    startedAt: (Number.isFinite(parsedStartedAt) ? parsedStartedAt : Date.now()) / 1000 - 978307200,
  };
  const aps = {
    timestamp: Math.floor(Date.now() / 1000),
    event,
    "content-state": contentState,
  };
  if (event === "start") {
    // iOS 18+ 要求显式请求该活动自己的 update token；App 随后会回传 Relay。
    aps["input-push-token"] = 1;
    aps["attributes-type"] = "AirSIMCallActivityAttributes";
    aps.attributes = { moduleName: "AirSIM" };
    aps.alert = { title: displayName, body: "模块语音来电", sound: "default" };
  }
  return { aps };
}

async function authenticate(event, env) {
  if (!nonEmpty(event.device_id) || typeof event.device_secret !== "string") {
    return { response: jsonResponse(401, { error: "unauthorized" }) };
  }
  const device = await readDeviceRecord(env, event.device_id.trim());
  if (!device) return { response: jsonResponse(401, { error: "unauthorized" }) };
  const suppliedHash = await sha256Hex(event.device_secret);
  if (!constantTimeEqual(device.secret_hash, suppliedHash)) {
    return { response: jsonResponse(401, { error: "unauthorized" }) };
  }
  return { device };
}

export async function sendAPNs(env, device, token, options) {
  const body = JSON.stringify(options.payload);
  if (encoder.encode(body).byteLength > MAX_APNS_PAYLOAD_BYTES) {
    throw new Error("APNs payload too large");
  }
  const providerToken = await createProviderToken(env);
  const origin = device.environment === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
  const response = await fetch(`${origin}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${providerToken}`,
      "content-type": "application/json",
      "apns-push-type": options.pushType,
      "apns-priority": options.priority,
      "apns-topic": options.topic,
      "apns-expiration": String(options.expiration),
      "apns-collapse-id": await boundedCollapseID(options.collapseID),
    },
    body,
  });
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 1024);
    throw new Error(`APNs HTTP ${response.status}: ${detail}`);
  }
}

export async function createProviderToken(env, now = Date.now()) {
  if (!env.APNS_TEAM_ID || !env.APNS_KEY_ID || !env.APNS_P8) {
    throw new Error("APNs credentials are incomplete");
  }
  const cacheKey = `${env.APNS_TEAM_ID}:${env.APNS_KEY_ID}`;
  if (cachedProviderToken && cachedProviderTokenKey === cacheKey &&
      now - cachedProviderTokenAt < 50 * 60 * 1000) {
    return cachedProviderToken;
  }

  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64url(encoder.encode(JSON.stringify({
    iss: env.APNS_TEAM_ID,
    iat: Math.floor(now / 1000),
  })));
  const unsigned = `${header}.${claims}`;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(env.APNS_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const generated = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    encoder.encode(unsigned),
  ));
  const signature = normalizeECDSASignature(generated);
  cachedProviderToken = `${unsigned}.${base64url(signature)}`;
  cachedProviderTokenAt = now;
  cachedProviderTokenKey = cacheKey;
  return cachedProviderToken;
}

export function validateRegistration(device, allowedBundleID) {
  if (!nonEmpty(device.device_id) || device.device_id.trim().length > 128 ||
      typeof device.device_secret !== "string" || device.device_secret.length < 16 ||
      device.device_secret.length > 512) return "invalid device identity";
  const voip = device.voip_token || "";
  const alert = device.alert_token || "";
  const watchVoIP = device.watch_voip_token || "";
  const liveActivity = device.live_activity_push_to_start_token || "";
  if (!voip && !alert && !watchVoIP && !liveActivity) return "at least one APNs token is required";
  if ((voip && !TOKEN_PATTERN.test(voip)) || (alert && !TOKEN_PATTERN.test(alert)) ||
      (watchVoIP && !TOKEN_PATTERN.test(watchVoIP)) ||
      (liveActivity && !TOKEN_PATTERN.test(liveActivity))) {
    return "invalid APNs token";
  }
  if (device.bundle_id !== allowedBundleID) return "bundle id is not allowed";
  if (watchVoIP && device.watch_bundle_id !== `${allowedBundleID}.watchkitapp`) {
    return "watch bundle id is not allowed";
  }
  if (device.environment !== "sandbox" && device.environment !== "production") {
    return "invalid APNs environment";
  }
  return "";
}

async function readJSON(request) {
  const declared = Number(request.headers.get("content-length") || "0");
  if (declared > MAX_BODY_BYTES) throw new Error("request body too large");
  const body = await request.text();
  if (encoder.encode(body).byteLength > MAX_BODY_BYTES) throw new Error("request body too large");
  const value = JSON.parse(body);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid JSON");
  return value;
}

async function readRelayRecord(env, key) {
  const value = await readRelayState(env, key);
  if (!value) return null;
  try { return JSON.parse(value); } catch { return null; }
}

function deviceKey(deviceID) {
  return `device:${deviceID.trim()}`;
}

async function boundedCollapseID(value) {
  const text = stringValue(value);
  if (encoder.encode(text).byteLength <= 64) return text;
  return `airsim-${(await sha256Hex(text)).slice(0, 57)}`;
}

async function sha256Hex(value) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(left, right) {
  if (typeof left !== "string" || typeof right !== "string") return false;
  let difference = left.length ^ right.length;
  const maximum = Math.max(left.length, right.length);
  for (let index = 0; index < maximum; index += 1) {
    difference |= (left.charCodeAt(index % Math.max(left.length, 1)) || 0) ^
      (right.charCodeAt(index % Math.max(right.length, 1)) || 0);
  }
  return difference === 0;
}

function truncateCodePoints(value, maximum) {
  const points = [...value];
  if (points.length <= maximum) return [value, false];
  return [points.slice(0, maximum).join("") + "…", true];
}

function normalizeECDSASignature(signature) {
  if (signature.length === 64) return signature;
  if (signature[0] !== 0x30) throw new Error("unsupported ECDSA signature encoding");
  let offset = 2;
  if (signature[1] & 0x80) offset = 2 + (signature[1] & 0x7f);
  if (signature[offset++] !== 0x02) throw new Error("invalid ECDSA signature");
  const rLength = signature[offset++];
  const r = signature.slice(offset, offset + rLength); offset += rLength;
  if (signature[offset++] !== 0x02) throw new Error("invalid ECDSA signature");
  const sLength = signature[offset++];
  const s = signature.slice(offset, offset + sLength);
  const raw = new Uint8Array(64);
  raw.set(r.slice(Math.max(0, r.length - 32)), 32 - Math.min(32, r.length));
  raw.set(s.slice(Math.max(0, s.length - 32)), 64 - Math.min(32, s.length));
  return raw;
}

function pemToBytes(pem) {
  const encoded = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  if (!encoded) throw new Error("APNs P8 is not PEM");
  return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
}

function base64url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function nonEmpty(value) {
  return typeof value === "string" && value.trim() !== "";
}

function stringValue(value) {
  return typeof value === "string" ? value : "";
}

function safeError(error) {
  return error instanceof Error ? error.message.slice(0, 1024) : "unknown error";
}

function jsonResponse(status, value) {
  return new Response(JSON.stringify(value) + "\n", {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
