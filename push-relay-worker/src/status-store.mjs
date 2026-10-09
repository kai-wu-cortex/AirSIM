const HEARTBEAT_PREFIX = "heartbeat:";
const DEVICE_PREFIX = "device:";
const DASHBOARD_EVENT_PREFIX = "dashboard:event:";
const REGISTRY_NAME = "agent-heartbeats";

export class AgentStatusRegistry {
  constructor(state) {
    this.storage = state.storage;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/heartbeat\/([^/]+)$/);
    const agentMatch = url.pathname.match(/^\/heartbeat\/([^/]+)\/([^/]+)$/);
    const rosterMatch = url.pathname.match(/^\/heartbeats\/([^/]+)$/);
    const rateMatch = url.pathname.match(/^\/rate\/([^/]+)$/);
    const deviceMatch = url.pathname.match(/^\/device\/([^/]+)$/);
    const stateMatch = url.pathname.match(/^\/state\/([^/]+)$/);

    if (url.pathname === "/events") {
      if (request.method === "POST") {
        const { key, record, expires_at_ms: expiresAtMS } = await request.json();
        if (typeof key !== "string" || !key.startsWith(DASHBOARD_EVENT_PREFIX) ||
            !record || typeof record !== "object") {
          return Response.json({ error: "invalid event record" }, { status: 400 });
        }
        await this.storage.put(key, {
          value: record,
          expires_at_ms: Number.isFinite(expiresAtMS) ? expiresAtMS : null,
        });
        return Response.json({ stored: true }, { status: 202 });
      }
      if (request.method === "GET") {
        const requestedLimit = Number(url.searchParams.get("limit"));
        const limit = Number.isFinite(requestedLimit)
          ? Math.max(1, Math.min(100, Math.floor(requestedLimit)))
          : 60;
        const entries = await this.storage.list({ prefix: DASHBOARD_EVENT_PREFIX, limit: 1_000 });
        const now = Date.now();
        const records = [];
        for (const [key, stored] of entries) {
          if (Number.isFinite(stored?.expires_at_ms) && stored.expires_at_ms <= now) {
            await this.storage.delete(key);
            continue;
          }
          if (stored?.value && typeof stored.value === "object") records.push(stored.value);
          if (records.length >= limit) break;
        }
        return Response.json(records);
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (stateMatch) {
      const key = decodeURIComponent(stateMatch[1]);
      if (request.method === "PUT") {
        const { value, ttl_seconds: ttlSeconds } = await request.json();
        const ttl = Number(ttlSeconds);
        await this.storage.put(key, {
          value,
          expires_at_ms: Number.isFinite(ttl) && ttl > 0 ? Date.now() + ttl * 1_000 : null,
        });
        return Response.json({ stored: true }, { status: 202 });
      }
      if (request.method === "GET") {
        const record = await this.storage.get(key);
        if (!record) return Response.json({ error: "not found" }, { status: 404 });
        if (Number.isFinite(record.expires_at_ms) && record.expires_at_ms <= Date.now()) {
          await this.storage.delete(key);
          return Response.json({ error: "not found" }, { status: 404 });
        }
        return Response.json({ value: record.value });
      }
      if (request.method === "DELETE") {
        await this.storage.delete(key);
        return new Response(null, { status: 204 });
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (url.pathname === "/devices" && request.method === "GET") {
      const entries = await this.storage.list({ prefix: DEVICE_PREFIX });
      return Response.json([...entries.values()]);
    }

    if (deviceMatch) {
      const key = `${DEVICE_PREFIX}${decodeURIComponent(deviceMatch[1])}`;
      if (request.method === "PUT") {
        const record = await request.json();
        await this.storage.put(key, record);
        return Response.json({ stored: true }, { status: 202 });
      }
      if (request.method === "GET") {
        const record = await this.storage.get(key);
        return record
          ? Response.json(record)
          : Response.json({ error: "not found" }, { status: 404 });
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (rateMatch) {
      const key = `rate:${decodeURIComponent(rateMatch[1])}`;
      if (request.method === "PUT") {
        const { now, window_ms: windowMS } = await request.json();
        const previous = Number(await this.storage.get(key));
        if (Number.isFinite(previous) && now - previous < windowMS) {
          return Response.json({ allowed: false, retry_after_ms: windowMS - (now - previous) });
        }
        await this.storage.put(key, now);
        return Response.json({ allowed: true });
      }
      if (request.method === "DELETE") {
        await this.storage.delete(key);
        return new Response(null, { status: 204 });
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (rosterMatch && request.method === "GET") {
      const deviceID = decodeURIComponent(rosterMatch[1]);
      const prefix = `${HEARTBEAT_PREFIX}${deviceID}:agent:`;
      const entries = await this.storage.list({ prefix });
      return Response.json([...entries.values()]);
    }

    if (agentMatch) {
      const deviceID = decodeURIComponent(agentMatch[1]);
      const agentID = decodeURIComponent(agentMatch[2]);
      const key = `${HEARTBEAT_PREFIX}${deviceID}:agent:${agentID}`;
      if (request.method === "PUT") {
        const record = await request.json();
        await this.storage.put(key, record);
        return Response.json({ stored: true }, { status: 202 });
      }
      if (request.method === "GET") {
        const record = await this.storage.get(key);
        return record ? Response.json(record) : Response.json({ error: "not found" }, { status: 404 });
      }
      return new Response("method not allowed", { status: 405 });
    }

    if (!match) return new Response("not found", { status: 404 });
    const deviceID = decodeURIComponent(match[1]);
    const key = `${HEARTBEAT_PREFIX}${deviceID}`;

    if (request.method === "PUT") {
      const record = await request.json();
      await this.storage.put(key, record);
      return Response.json({ stored: true }, { status: 202 });
    }
    if (request.method === "GET") {
      const record = await this.storage.get(key);
      return record
        ? Response.json(record)
        : Response.json({ error: "not found" }, { status: 404 });
    }
    return new Response("method not allowed", { status: 405 });
  }
}

function registryStub(env) {
  if (!env.STATUS) return null;
  return env.STATUS.get(env.STATUS.idFromName(REGISTRY_NAME));
}

export async function writeAgentHeartbeat(env, deviceID, agentID, record) {
  const normalizedAgentID = agentID || "legacy";
  const stub = registryStub(env);
  if (!stub) {
    // Keep local tests and an intentionally old deployment configuration working.
    await env.DEVICES.put(`${HEARTBEAT_PREFIX}${deviceID}`, JSON.stringify(record), {
      expirationTtl: 300,
    });
    await env.DEVICES.put(
      `${HEARTBEAT_PREFIX}${deviceID}:agent:${normalizedAgentID}`,
      JSON.stringify(record),
      { expirationTtl: 30 * 24 * 60 * 60 },
    );
    return;
  }
  const options = {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(record),
  };
  const [response, legacyResponse] = await Promise.all([
    stub.fetch(
      `https://status.internal/heartbeat/${encodeURIComponent(deviceID)}/${encodeURIComponent(normalizedAgentID)}`,
      options,
    ),
    stub.fetch(`https://status.internal/heartbeat/${encodeURIComponent(deviceID)}`, options),
  ]);
  if (!response.ok) throw new Error(`status registry returned HTTP ${response.status}`);
  if (!legacyResponse.ok) throw new Error(`status registry returned HTTP ${legacyResponse.status}`);
}

export async function readAgentHeartbeats(env, deviceID) {
  const stub = registryStub(env);
  if (stub) {
    try {
      const response = await stub.fetch(
        `https://status.internal/heartbeats/${encodeURIComponent(deviceID)}`,
      );
      if (response.ok) {
        const records = await response.json();
        if (Array.isArray(records) && records.length > 0) return records;
      }
    } catch (error) {
      console.warn("status registry roster read failed; using KV mirrors", safeError(error));
    }
  }
  try {
    const prefix = `${HEARTBEAT_PREFIX}${deviceID}:agent:`;
    const listing = await env.DEVICES.list({ prefix, limit: 100 });
    const records = await Promise.all((listing.keys || []).map((item) => readKVRecord(env.DEVICES, item.name)));
    const available = records.filter(Boolean);
    if (available.length > 0) return available;
  } catch (error) {
    console.warn("KV heartbeat roster read failed; using latest heartbeat", safeError(error));
  }
  const latest = await readAgentHeartbeat(env, deviceID);
  return latest ? [latest] : [];
}

export async function readAgentHeartbeat(env, deviceID) {
  const stub = registryStub(env);
  if (!stub) return readKVRecord(env.DEVICES, `${HEARTBEAT_PREFIX}${deviceID}`);
  try {
    const response = await stub.fetch(
      `https://status.internal/heartbeat/${encodeURIComponent(deviceID)}`,
    );
    if (response.ok) return response.json();
    if (response.status !== 404) {
      console.warn(`status registry returned HTTP ${response.status}; using KV heartbeat mirror`);
    }
  } catch (error) {
    console.warn("status registry heartbeat read failed; using KV mirror", safeError(error));
  }
  return readKVRecord(env.DEVICES, `${HEARTBEAT_PREFIX}${deviceID}`);
}

export async function writeDeviceRecord(env, deviceID, record) {
  const stub = registryStub(env);
  if (!stub) {
    await env.DEVICES.put(`${DEVICE_PREFIX}${deviceID}`, JSON.stringify(record));
    return;
  }
  const response = await stub.fetch(`https://status.internal/device/${encodeURIComponent(deviceID)}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(record),
  });
  if (!response.ok) throw new Error(`device registry returned HTTP ${response.status}`);
  await bestEffortKVPut(env.DEVICES, `${DEVICE_PREFIX}${deviceID}`, record);
}

export async function readDeviceRecord(env, deviceID) {
  const stub = registryStub(env);
  if (stub) {
    const response = await stub.fetch(`https://status.internal/device/${encodeURIComponent(deviceID)}`);
    if (response.ok) return response.json();
    if (response.status !== 404) throw new Error(`device registry returned HTTP ${response.status}`);
  }
  return readKVRecord(env.DEVICES, `${DEVICE_PREFIX}${deviceID}`);
}

export async function listDeviceRecords(env) {
  const records = new Map();
  const stub = registryStub(env);
  let registryAvailable = false;
  if (stub) {
    try {
      const response = await stub.fetch("https://status.internal/devices");
      if (!response.ok) throw new Error(`device registry returned HTTP ${response.status}`);
      registryAvailable = true;
      for (const record of await response.json()) {
        if (record?.device_id) records.set(record.device_id, record);
      }
    } catch (error) {
      console.warn("device registry list failed; using KV mirrors", safeError(error));
    }
  }
  if (!registryAvailable && typeof env.DEVICES?.list === "function") {
    try {
      const keys = await env.DEVICES.list({ prefix: DEVICE_PREFIX, limit: 500 });
      for (const item of keys?.keys || []) {
        const record = await readKVRecord(env.DEVICES, item.name);
        if (record?.device_id && !records.has(record.device_id)) records.set(record.device_id, record);
      }
    } catch (error) {
      console.warn("KV device mirror list failed; using status registry records", safeError(error));
    }
  }
  return [...records.values()];
}

export async function writeDashboardEvent(env, key, record, ttlSeconds) {
  const stub = registryStub(env);
  if (!stub) {
    await bestEffortKVPut(env.DEVICES, key, record, { expirationTtl: ttlSeconds });
    return;
  }
  const response = await stub.fetch("https://status.internal/events", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      key,
      record,
      expires_at_ms: Date.now() + ttlSeconds * 1_000,
    }),
  });
  if (!response.ok) throw new Error(`dashboard event registry returned HTTP ${response.status}`);
}

export async function listDashboardEvents(env, limit = 60) {
  const stub = registryStub(env);
  if (stub) {
    try {
      const response = await stub.fetch(
        `https://status.internal/events?limit=${encodeURIComponent(limit)}`,
      );
      if (!response.ok) throw new Error(`dashboard event registry returned HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      console.warn("dashboard event registry unavailable; using KV fallback", safeError(error));
    }
  }
  if (typeof env.DEVICES?.list !== "function") return [];
  try {
    const result = await env.DEVICES.list({ prefix: DASHBOARD_EVENT_PREFIX, limit });
    const records = [];
    for (const item of result?.keys || []) {
      const record = await readKVRecord(env.DEVICES, item.name);
      if (record) records.push(record);
    }
    return records;
  } catch (error) {
    console.warn("KV dashboard events unavailable", safeError(error));
    return [];
  }
}

export async function writeRelayState(env, key, value, ttlSeconds = null) {
  const stub = registryStub(env);
  if (!stub) {
    const options = Number.isFinite(ttlSeconds) && ttlSeconds > 0
      ? { expirationTtl: ttlSeconds }
      : undefined;
    await env.DEVICES.put(key, value, options);
    return;
  }
  const response = await stub.fetch(`https://status.internal/state/${encodeURIComponent(key)}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ value, ttl_seconds: ttlSeconds }),
  });
  if (!response.ok) throw new Error(`relay state registry returned HTTP ${response.status}`);
}

export async function readRelayState(env, key) {
  const stub = registryStub(env);
  if (stub) {
    const response = await stub.fetch(`https://status.internal/state/${encodeURIComponent(key)}`);
    if (response.ok) return (await response.json()).value ?? null;
    if (response.status !== 404) throw new Error(`relay state registry returned HTTP ${response.status}`);
  }
  return env.DEVICES.get(key);
}

export async function deleteRelayState(env, key) {
  const stub = registryStub(env);
  if (stub) {
    const response = await stub.fetch(`https://status.internal/state/${encodeURIComponent(key)}`, {
      method: "DELETE",
    });
    if (!response.ok) throw new Error(`relay state registry returned HTTP ${response.status}`);
    return;
  }
  await env.DEVICES.delete(key);
}

export async function claimRateLimit(env, key, now, windowMS) {
  const stub = registryStub(env);
  if (!stub) {
    const kvKey = `dashboard:virtual-call-rate:${key}`;
    const previous = Number(await env.DEVICES.get(kvKey));
    if (Number.isFinite(previous) && now - previous < windowMS) return false;
    await env.DEVICES.put(kvKey, String(now), { expirationTtl: 60 });
    return true;
  }
  const response = await stub.fetch(`https://status.internal/rate/${encodeURIComponent(key)}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ now, window_ms: windowMS }),
  });
  if (!response.ok) throw new Error(`status rate limiter returned HTTP ${response.status}`);
  return (await response.json()).allowed === true;
}

export async function clearRateLimit(env, key) {
  const stub = registryStub(env);
  if (!stub) {
    await env.DEVICES.delete(`dashboard:virtual-call-rate:${key}`);
    return;
  }
  const response = await stub.fetch(`https://status.internal/rate/${encodeURIComponent(key)}`, {
    method: "DELETE",
  });
  if (!response.ok) throw new Error(`status rate limiter returned HTTP ${response.status}`);
}

async function readKVRecord(kv, key) {
  if (typeof kv?.get !== "function") return null;
  const value = await kv.get(key);
  if (!value) return null;
  try { return JSON.parse(value); } catch { return null; }
}

async function bestEffortKVPut(kv, key, record, options) {
  if (typeof kv?.put !== "function") return;
  try {
    await kv.put(key, JSON.stringify(record), options);
  } catch {
    // Durable Object remains authoritative when KV is exhausted or unavailable.
  }
}

function safeError(error) {
  return error instanceof Error ? error.message : String(error);
}
