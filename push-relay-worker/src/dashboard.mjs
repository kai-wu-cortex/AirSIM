const DASHBOARD_EVENT_PREFIX = "dashboard:event:";
const DEVICE_PREFIX = "device:";
import {
  claimRateLimit,
  clearRateLimit,
  listDashboardEvents,
  listDeviceRecords,
  readAgentHeartbeat,
  writeDashboardEvent,
} from "./status-store.mjs";
const DASHBOARD_EVENT_TTL_SECONDS = 7 * 24 * 60 * 60;

export function dashboardHTMLResponse() {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  return new Response(dashboardHTML(nonce), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "content-security-policy": `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
    },
  });
}

export function dashboardAuthorized(request, env) {
  const expected = typeof env.DASHBOARD_TOKEN === "string" ? env.DASHBOARD_TOKEN.trim() : "";
  if (!expected) return { configured: false, authorized: false };
  const header = request.headers.get("authorization") || "";
  const supplied = header.toLowerCase().startsWith("bearer ") ? header.slice(7).trim() : "";
  return { configured: true, authorized: constantTimeEqual(expected, supplied) };
}

export async function dashboardSummary(env, now = Date.now()) {
  const devices = [];
  for (const device of await listDeviceRecords(env)) {
    if (!device?.device_id) continue;
    const controlID = await dashboardControlID(env, device.device_id);
    const heartbeat = await readAgentHeartbeat(env, device.device_id);
    const heartbeatAt = Number(heartbeat?.received_at_ms || 0);
    const ageSeconds = heartbeatAt > 0 ? Math.max(0, Math.floor((now - heartbeatAt) / 1000)) : null;
    devices.push({
      id: maskDeviceID(device.device_id),
      control_id: controlID,
      environment: device.environment === "production" ? "production" : "sandbox",
      registered_at: safeISODate(device.registered_at),
      online: ageSeconds !== null && ageSeconds <= 90,
      heartbeat_age_seconds: ageSeconds,
      agent_version: stringValue(heartbeat?.agent_version),
      cellular_state: allowedCellularState(heartbeat?.cellular_state),
      at_ok: heartbeat?.at_ok === true,
      ecm_carrier: heartbeat?.ecm_carrier === "1",
      signal_dbm: Number.isFinite(heartbeat?.signal_dbm) ? heartbeat.signal_dbm : null,
      push: {
        iphone: Boolean(device.voip_token),
        alert: Boolean(device.alert_token),
        watch: Boolean(device.watch_voip_token),
        live_activity: Boolean(device.live_activity_push_to_start_token),
      },
    });
  }
  devices.sort((left, right) => Number(right.online) - Number(left.online) || left.id.localeCompare(right.id));

  const events = [];
  for (const event of await listDashboardEvents(env, 60)) {
    if (!event || !safeISODate(event.at)) continue;
    events.push({
      at: event.at,
      type: allowedEventType(event.type),
      device_id: maskDeviceID(event.device_id),
      status: event.status === "failed" ? "failed" : "delivered",
      channel: allowedChannel(event.channel),
      environment: event.environment === "production" ? "production" : event.environment === "sandbox" ? "sandbox" : "",
    });
  }

  const online = devices.filter((device) => device.online).length;
  return {
    generated_at: new Date(now).toISOString(),
    service: { ok: true, name: "AirSIM Push Relay", version: "0.2.0" },
    metrics: {
      devices: devices.length,
      online,
      production: devices.filter((device) => device.environment === "production").length,
      push_ready: devices.filter((device) => device.push.iphone && device.push.alert).length,
    },
    devices,
    events,
  };
}

export async function dashboardVirtualCall(request, env, sendAPNs) {
  let value;
  try {
    const body = await request.text();
    if (new TextEncoder().encode(body).byteLength > 8 * 1024) {
      return jsonResponse(413, { error: "请求内容过长" });
    }
    value = JSON.parse(body);
  } catch {
    return jsonResponse(400, { error: "请求格式无效" });
  }
  const controlID = stringValue(value?.device_id).trim();
  const title = normalizedText(value?.title, 48);
  const content = normalizedText(value?.content, 280);
  if (!/^[0-9a-f]{32}$/.test(controlID) || !title || !content) {
    return jsonResponse(400, { error: "请选择设备，并填写 48 字以内标题和 280 字以内播报内容" });
  }

  const device = await findDashboardDevice(env, controlID);
  if (!device) return jsonResponse(404, { error: "设备不存在或已重新注册" });
  if (!device.voip_token) return jsonResponse(409, { error: "该设备没有可用的 VoIP Token" });

  const now = Date.now();
  if (!await claimRateLimit(env, controlID, now, 10_000)) {
    return jsonResponse(429, { error: "操作太频繁，请等待 10 秒后重试" });
  }

  const callUUID = crypto.randomUUID();
  const callID = `dashboard-virtual-${callUUID}`;
  const expiresAt = now + 90_000;
  const payload = {
    aps: { "content-available": 1 },
    event: "incoming_call",
    call_id: callID,
    call_uuid: callUUID,
    number: title,
    caller_name: title,
    virtual_call: true,
    tts_text: content,
    issued_at: new Date(now).toISOString(),
    expires_at: new Date(expiresAt).toISOString(),
  };
  try {
    await sendAPNs(env, device, device.voip_token, {
      topic: `${device.bundle_id}.voip`,
      pushType: "voip",
      priority: "10",
      expiration: Math.floor(expiresAt / 1000),
      collapseID: callUUID,
      payload,
    });
    await recordDashboardEvent(env, {
      type: "virtual_call", device_id: device.device_id, status: "delivered",
      channel: "iphone", environment: device.environment,
    });
    return jsonResponse(202, { sent: true, call_uuid: callUUID });
  } catch {
    await clearRateLimit(env, controlID);
    await recordDashboardEvent(env, {
      type: "virtual_call", device_id: device.device_id, status: "failed",
      channel: "iphone", environment: device.environment,
    });
    return jsonResponse(502, { error: "Apple Push 投递失败，请检查设备 Token 与 APNs 环境" });
  }
}

export async function recordDashboardEvent(env, event) {
  if (!env.DEVICES || !event?.device_id) return;
  const now = Date.now();
  const reverseTimestamp = String(9_999_999_999_999 - now).padStart(13, "0");
  const key = `${DASHBOARD_EVENT_PREFIX}${reverseTimestamp}:${crypto.randomUUID()}`;
  const value = {
    at: new Date(now).toISOString(),
    type: allowedEventType(event.type),
    device_id: stringValue(event.device_id).slice(0, 128),
    status: event.status === "failed" ? "failed" : "delivered",
    channel: allowedChannel(event.channel),
    environment: event.environment === "production" ? "production" : event.environment === "sandbox" ? "sandbox" : "",
  };
  try {
    await writeDashboardEvent(env, key, value, DASHBOARD_EVENT_TTL_SECONDS);
  } catch {
    // Dashboard telemetry must never delay or fail a call, SMS, or registration.
  }
}

function maskDeviceID(value) {
  const text = stringValue(value).trim();
  if (!text) return "未知设备";
  if (text.length <= 12) return text.slice(0, 3) + "…" + text.slice(-2);
  return text.slice(0, 8) + "…" + text.slice(-4);
}

function safeISODate(value) {
  const timestamp = Date.parse(stringValue(value));
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : "";
}

function allowedCellularState(value) {
  return ["registered", "searching", "denied", "unregistered"].includes(value) ? value : "unknown";
}

function allowedEventType(value) {
  return ["registration", "call", "sms", "call_owner", "virtual_call"].includes(value) ? value : "system";
}

function allowedChannel(value) {
  return ["iphone", "watch", "alert", "live_activity", "relay"].includes(value) ? value : "relay";
}

function stringValue(value) {
  return typeof value === "string" ? value : "";
}

function constantTimeEqual(left, right) {
  if (!left || !right) return false;
  let difference = left.length ^ right.length;
  const maximum = Math.max(left.length, right.length);
  for (let index = 0; index < maximum; index += 1) {
    difference |= left.charCodeAt(index % left.length) ^ right.charCodeAt(index % right.length);
  }
  return difference === 0;
}

async function dashboardControlID(env, deviceID) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.DASHBOARD_TOKEN),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "HMAC", key, new TextEncoder().encode(deviceID),
  ));
  return [...signature.slice(0, 16)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function findDashboardDevice(env, controlID) {
  for (const device of await listDeviceRecords(env)) {
    if (device?.device_id && constantTimeEqual(await dashboardControlID(env, device.device_id), controlID)) {
      return device;
    }
  }
  return null;
}

function normalizedText(value, maximum) {
  const text = stringValue(value).trim().replace(/\s+/g, " ");
  const points = [...text];
  if (!points.length || points.length > maximum) return "";
  return text;
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

function dashboardHTML(nonce) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="color-scheme" content="light">
  <title>AirSIM Relay</title>
  <style nonce="${nonce}">
    :root{--canvas:#f4f7f4;--paper:#fff;--ink:#14221c;--muted:#6e7c75;--line:#dce5df;--blue:#1a67ff;--green:#18a66a;--amber:#e99a2c;--red:#d54e4e;--shadow:0 22px 60px rgba(28,62,45,.10);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;color:var(--ink);background:var(--canvas)}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:linear-gradient(135deg,#f7faf7 0%,#edf4ef 100%);letter-spacing:-.01em}button,input,textarea{font:inherit}button{cursor:pointer}.shell{width:min(1180px,calc(100% - 40px));margin:0 auto;padding:42px 0 64px}.mast{display:flex;align-items:flex-start;justify-content:space-between;gap:32px;margin-bottom:34px}.eyebrow{display:flex;align-items:center;gap:10px;color:var(--green);font:700 12px/1 ui-monospace,"SFMono-Regular",monospace;letter-spacing:.12em;text-transform:uppercase}.pulse{width:9px;height:9px;border-radius:50%;background:var(--green);box-shadow:0 0 0 5px rgba(24,166,106,.12)}h1{margin:12px 0 8px;font-family:ui-rounded,"SF Pro Rounded","PingFang SC",sans-serif;font-size:clamp(34px,5vw,64px);line-height:.98;letter-spacing:-.06em}.subtitle{margin:0;color:var(--muted);font-size:15px}.toolbar{display:flex;align-items:center;gap:10px}.button{min-height:42px;border:1px solid var(--line);border-radius:999px;background:rgba(255,255,255,.76);padding:0 17px;color:var(--ink);box-shadow:0 8px 24px rgba(28,62,45,.06)}.button:focus-visible,.token:focus-visible,.field:focus-visible,.device:focus-visible,.close:focus-visible{outline:3px solid rgba(26,103,255,.25);outline-offset:2px}.button.primary{border-color:var(--blue);background:var(--blue);color:#fff}.button:disabled{cursor:default;opacity:.55}.signal-rail{display:grid;grid-template-columns:1fr auto 1fr auto 1fr;align-items:center;gap:14px;padding:22px 24px;margin-bottom:18px;border:1px solid rgba(207,220,211,.9);border-radius:24px;background:rgba(255,255,255,.74);box-shadow:var(--shadow);backdrop-filter:blur(24px)}.node{display:flex;align-items:center;gap:12px;min-width:0}.node-icon{display:grid;place-items:center;width:42px;height:42px;border-radius:14px;background:#edf2ef;color:var(--ink);font-weight:800}.node.good .node-icon{background:#e2f5eb;color:var(--green)}.node-copy strong{display:block;font-size:14px}.node-copy span{display:block;margin-top:3px;color:var(--muted);font-size:12px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rail{width:48px;height:2px;background:linear-gradient(90deg,var(--green),rgba(24,166,106,.18));position:relative}.rail:after{content:"";position:absolute;right:0;top:-3px;width:8px;height:8px;border-radius:50%;background:var(--green)}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.metric,.panel{border:1px solid var(--line);background:rgba(255,255,255,.88);box-shadow:0 12px 34px rgba(28,62,45,.06)}.metric{min-height:136px;border-radius:22px;padding:21px}.metric-label{color:var(--muted);font-size:13px}.metric-value{margin-top:14px;font:750 38px/1 ui-rounded,"SF Pro Rounded",sans-serif;letter-spacing:-.05em}.metric-note{margin-top:10px;color:var(--muted);font-size:12px}.content{display:grid;grid-template-columns:minmax(0,1.45fr) minmax(300px,.75fr);gap:18px;margin-top:18px}.panel{border-radius:26px;overflow:hidden}.panel-head{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:22px 24px;border-bottom:1px solid var(--line)}.panel-head h2{margin:0;font:700 18px/1.2 ui-rounded,"SF Pro Rounded",sans-serif}.panel-head span{color:var(--muted);font-size:12px}.device-list,.event-list{list-style:none;margin:0;padding:0}.device,.event{display:grid;align-items:center;gap:14px;padding:18px 24px;border-bottom:1px solid var(--line)}.device:last-child,.event:last-child{border-bottom:0}.device{grid-template-columns:minmax(130px,1fr) 110px minmax(210px,auto) 116px;transition:background .2s ease,transform .2s ease;cursor:pointer}.device:hover{background:#f7faf8}.device:active{transform:scale(.995)}.device-id{font:650 13px/1.3 ui-monospace,"SFMono-Regular",monospace}.small{display:block;margin-top:4px;color:var(--muted);font-size:11px}.badge{display:inline-flex;align-items:center;gap:7px;width:max-content;padding:7px 10px;border-radius:999px;background:#edf2ef;color:var(--muted);font-size:11px;font-weight:650}.badge:before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}.badge.good{background:#e2f5eb;color:var(--green)}.badge.warn{background:#fff1db;color:#b56d0b}.pushes{display:flex;flex-wrap:wrap;gap:5px}.push{height:25px;border-radius:8px;display:grid;place-items:center;padding:0 8px;background:#edf2ef;color:#94a098;font:650 10px/1 -apple-system,BlinkMacSystemFont,sans-serif}.push.on{background:#e7efff;color:var(--blue)}.signal{font:700 13px/1 ui-monospace,monospace}.event{grid-template-columns:12px minmax(0,1fr) auto}.event-mark{width:9px;height:9px;border-radius:50%;background:var(--blue)}.event.failed .event-mark{background:var(--red)}.event-title{font-size:13px;font-weight:650}.event-meta{margin-top:4px;color:var(--muted);font-size:11px}.event-time{color:var(--muted);font:600 11px/1 ui-monospace,monospace}.empty{padding:42px 24px;text-align:center;color:var(--muted);font-size:13px}.login{position:fixed;inset:0;display:grid;place-items:center;padding:24px;background:rgba(239,245,241,.84);backdrop-filter:blur(20px);z-index:5}.login[hidden]{display:none}.login-card{width:min(430px,100%);border:1px solid var(--line);border-radius:28px;background:var(--paper);padding:30px;box-shadow:var(--shadow)}.login-card h2{margin:16px 0 8px;font:750 28px/1 ui-rounded,"SF Pro Rounded",sans-serif;letter-spacing:-.04em}.login-card p{color:var(--muted);font-size:13px;line-height:1.55}.token{width:100%;height:50px;border:1px solid var(--line);border-radius:15px;padding:0 15px;background:#f8faf8;color:var(--ink)}.login-actions{display:flex;justify-content:flex-end;margin-top:14px}.error{min-height:18px;margin-top:10px;color:var(--red);font-size:12px}.scrim{position:fixed;inset:0;border:0;background:rgba(14,25,20,.28);backdrop-filter:blur(4px);z-index:9}.scrim[hidden],.drawer[hidden]{display:none}.drawer{position:fixed;z-index:10;top:14px;right:14px;bottom:14px;width:min(520px,calc(100% - 28px));overflow:auto;border:1px solid rgba(255,255,255,.9);border-radius:30px;background:rgba(249,252,250,.95);box-shadow:0 34px 100px rgba(13,35,24,.24);backdrop-filter:blur(30px);padding:26px;animation:drawer-in .34s cubic-bezier(.2,.8,.2,1)}@keyframes drawer-in{from{opacity:0;transform:translateX(28px) scale(.98)}}.drawer-head{display:flex;align-items:flex-start;justify-content:space-between;gap:18px}.drawer-kicker{color:var(--green);font:700 11px/1 ui-monospace,monospace;letter-spacing:.1em}.drawer h2{margin:8px 0 5px;font:750 28px/1 ui-rounded,"SF Pro Rounded",sans-serif}.close{width:42px;height:42px;border:0;border-radius:50%;background:#edf2ef;color:var(--ink);font-size:22px}.detail-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:22px 0}.detail{min-height:72px;padding:14px;border:1px solid var(--line);border-radius:17px;background:rgba(255,255,255,.78)}.detail span{display:block;color:var(--muted);font-size:11px}.detail strong{display:block;margin-top:7px;font-size:14px;overflow-wrap:anywhere}.channel-title,.call-form h3{margin:24px 0 11px;font-size:13px}.channel-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.channel{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:13px;border-radius:15px;background:#edf2ef;color:var(--muted);font-size:12px;font-weight:650}.channel.on{background:#e7efff;color:var(--blue)}.channel i{width:8px;height:8px;border-radius:50%;background:currentColor}.call-form{margin-top:24px;padding:20px;border-radius:22px;background:#14221c;color:#fff}.call-form h3{margin-top:0;font-size:18px}.call-form p{margin:0 0 16px;color:#aebbb4;font-size:12px;line-height:1.55}.field-label{display:block;margin:12px 0 7px;color:#dce5df;font-size:12px}.field{display:block;width:100%;border:1px solid #3b4a43;border-radius:14px;background:#223129;color:#fff;padding:12px 13px}.field::placeholder{color:#78867f}.field.textarea{min-height:105px;resize:vertical;line-height:1.5}.form-foot{display:flex;align-items:center;justify-content:space-between;gap:14px;margin-top:14px}.form-status{min-height:17px;color:#b9c6bf;font-size:11px}.call-form .button.primary{flex:0 0 auto}.toast{position:fixed;z-index:20;left:50%;bottom:30px;transform:translateX(-50%);padding:12px 16px;border-radius:999px;background:#14221c;color:#fff;box-shadow:var(--shadow);font-size:12px}.toast[hidden]{display:none}.skeleton{animation:pulse 1.4s ease-in-out infinite alternate}@keyframes pulse{to{opacity:.42}}@media(prefers-reduced-motion:reduce){*{animation:none!important;scroll-behavior:auto!important}}@media(max-width:980px){.device{grid-template-columns:minmax(130px,1fr) 110px 1fr}.device>:nth-child(4){grid-column:3}}@media(max-width:820px){.shell{width:min(100% - 24px,680px);padding-top:26px}.mast{display:block}.toolbar{margin-top:20px}.grid{grid-template-columns:repeat(2,1fr)}.content{grid-template-columns:1fr}.signal-rail{grid-template-columns:1fr}.rail{width:2px;height:22px;margin-left:20px;background:linear-gradient(var(--green),rgba(24,166,106,.18))}.rail:after{right:-3px;top:auto;bottom:0}.device{grid-template-columns:1fr auto}.device>:nth-child(3),.device>:nth-child(4){grid-column:auto}.panel-head{padding:18px}.device,.event{padding:16px 18px}}@media(max-width:560px){.drawer{inset:0;width:100%;border-radius:0;padding:22px 18px}.detail-grid,.channel-grid{grid-template-columns:1fr 1fr}}@media(max-width:460px){.grid{grid-template-columns:1fr 1fr}.metric{min-height:116px;padding:17px}.metric-value{font-size:31px}.device{grid-template-columns:1fr}.pushes{margin-top:2px}.detail-grid{grid-template-columns:1fr 1fr}.form-foot{align-items:stretch;flex-direction:column}.call-form .button.primary{width:100%}}
  </style>
</head>
<body>
  <main class="shell" aria-live="polite">
    <header class="mast"><div><div class="eyebrow"><span class="pulse"></span>EDGE RELAY / LIVE</div><h1>通信中继<br>运行台</h1><p class="subtitle" id="updated">等待安全连接</p></div><div class="toolbar"><button class="button" id="lock">锁定</button><button class="button primary" id="refresh">刷新状态</button></div></header>
    <section class="signal-rail" aria-label="中继链路"><div class="node good"><div class="node-icon">R</div><div class="node-copy"><strong>Relay</strong><span>Cloudflare Worker</span></div></div><div class="rail"></div><div class="node" id="agentNode"><div class="node-icon">A</div><div class="node-copy"><strong>Agent</strong><span id="agentLabel">读取中</span></div></div><div class="rail"></div><div class="node good"><div class="node-icon">P</div><div class="node-copy"><strong>APNs</strong><span>安全推送通道</span></div></div></section>
    <section class="grid" id="metrics"><article class="metric skeleton"><div class="metric-label">注册设备</div><div class="metric-value">—</div><div class="metric-note">读取中</div></article><article class="metric skeleton"><div class="metric-label">云端在线</div><div class="metric-value">—</div><div class="metric-note">90 秒心跳窗口</div></article><article class="metric skeleton"><div class="metric-label">Production</div><div class="metric-value">—</div><div class="metric-note">正式 APNs 环境</div></article><article class="metric skeleton"><div class="metric-label">Push 就绪</div><div class="metric-value">—</div><div class="metric-note">来电与通知均有效</div></article></section>
    <section class="content"><article class="panel"><div class="panel-head"><h2>设备链路</h2><span>不展示凭据与完整设备 ID</span></div><ul class="device-list" id="devices"><li class="empty">等待数据</li></ul></article><aside class="panel"><div class="panel-head"><h2>最近投递</h2><span>保留 7 天</span></div><ul class="event-list" id="events"><li class="empty">暂无投递记录</li></ul></aside></section>
  </main>
  <section class="login" id="login"><div class="login-card"><div class="node-icon">R</div><h2>连接运行台</h2><p>输入 Relay Dashboard Token。凭据只保存在当前浏览器标签页，关闭标签页后自动清除。</p><input class="token" id="token" type="password" autocomplete="current-password" placeholder="Dashboard Token"><div class="error" id="error"></div><div class="login-actions"><button class="button primary" id="connect">查看运行状态</button></div></div></section>
  <button class="scrim" id="scrim" aria-label="关闭设备详情" hidden></button>
  <aside class="drawer" id="drawer" role="dialog" aria-modal="true" aria-labelledby="drawerTitle" hidden>
    <div class="drawer-head"><div><div class="drawer-kicker">DEVICE CONTROL</div><h2 id="drawerTitle">设备详情</h2><span class="small" id="drawerSubtitle"></span></div><button class="close" id="closeDrawer" aria-label="关闭">×</button></div>
    <div class="detail-grid" id="detailGrid"></div>
    <h3 class="channel-title">推送通道</h3><div class="channel-grid" id="channelGrid"></div>
    <form class="call-form" id="virtualCallForm"><h3>虚拟来电 · 本地 TTS</h3><p>通过 VoIP Push 唤起目标 iPhone 的 CallKit；接听后由 iPhone 本地语音播报，不会占用模块语音通道。</p><label class="field-label" for="callTitle">来电标题</label><input class="field" id="callTitle" maxlength="48" autocomplete="off" placeholder="例如：Vibe Coding"><label class="field-label" for="callContent">来电内容</label><textarea class="field textarea" id="callContent" maxlength="280" placeholder="输入接听后需要播报的内容"></textarea><div class="form-foot"><span class="form-status" id="formStatus">内容不会写入 Relay 日志</span><button class="button primary" id="sendVirtualCall" type="submit">模拟来电</button></div></form>
  </aside>
  <div class="toast" id="toast" role="status" hidden></div>
  <script nonce="${nonce}">
    const $=s=>document.querySelector(s), tokenKey='airsim-dashboard-token'; let timer,selectedDevice,toastTimer,lastFocus;
    const escapeText=v=>String(v??'');
    const relative=iso=>{const s=Math.max(0,Math.floor((Date.now()-Date.parse(iso))/1000));if(s<60)return s+' 秒前';if(s<3600)return Math.floor(s/60)+' 分钟前';return Math.floor(s/3600)+' 小时前'};
    const stateLabel=s=>({registered:'已注册',searching:'搜索网络',denied:'注册被拒',unregistered:'未注册',unknown:'未知'})[s]||'未知';
    const eventLabel=t=>({registration:'设备注册',call:'来电推送',sms:'短信推送',call_owner:'通话接管',virtual_call:'虚拟来电',system:'系统事件'})[t]||'系统事件';
    function el(tag,className,text){const node=document.createElement(tag);if(className)node.className=className;if(text!==undefined)node.textContent=escapeText(text);return node}
    function scheduleLoad(){clearTimeout(timer);if(!document.hidden)timer=setTimeout(load,60000)}
    async function load(){const token=sessionStorage.getItem(tokenKey);if(!token){$('#login').hidden=false;return}const response=await fetch('/dashboard/api/summary',{headers:{authorization:'Bearer '+token},cache:'no-store'});if(response.status===401){sessionStorage.removeItem(tokenKey);$('#error').textContent='Token 无效，请重新输入。';$('#login').hidden=false;return}if(!response.ok)throw new Error(response.status===503?'服务器尚未配置 DASHBOARD_TOKEN':'读取运行状态失败');const data=await response.json();render(data);$('#login').hidden=true;scheduleLoad()}
    document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)load().catch(error=>{$('#error').textContent=error.message})});
    function render(data){$('#updated').textContent='更新于 '+new Date(data.generated_at).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit',second:'2-digit'});const m=data.metrics;$('#metrics').replaceChildren(...[['注册设备',m.devices,'KV 已登记'],['云端在线',m.online,'90 秒心跳窗口'],['Production',m.production,'正式 APNs 环境'],['Push 就绪',m.push_ready,'来电与通知均有效']].map(([label,value,note])=>{const card=el('article','metric');card.append(el('div','metric-label',label),el('div','metric-value',value),el('div','metric-note',note));return card}));const online=m.online>0;$('#agentNode').classList.toggle('good',online);$('#agentLabel').textContent=online?m.online+' 台 Agent 在线':'没有新鲜心跳';const devices=$('#devices');devices.replaceChildren();if(!data.devices.length)devices.append(el('li','empty','尚无注册设备'));for(const d of data.devices){const row=el('li','device');row.tabIndex=0;row.setAttribute('role','button');row.setAttribute('aria-label','查看设备 '+d.id+' 的详细信息');const identity=el('div');identity.append(el('div','device-id',d.id),el('span','small',(d.agent_version||'Agent —')+' · '+d.environment));const status=el('div');status.append(el('span','badge '+(d.online?'good':'warn'),d.online?'云端在线':'等待心跳'),el('span','small',d.heartbeat_age_seconds===null?'从未上报':d.heartbeat_age_seconds+' 秒前'));const pushes=el('div','pushes');for(const [key,label] of [['iphone','CallKit'],['alert','通知'],['watch','Watch'],['live_activity','实时活动']])pushes.append(el('span','push '+(d.push[key]?'on':''),label));const signal=el('div');signal.append(el('div','signal',d.signal_dbm===null?'—':d.signal_dbm+' dBm'),el('span','small',stateLabel(d.cellular_state)+' · '+(d.at_ok?'AT 正常':'AT 异常')));row.append(identity,status,pushes,signal);row.addEventListener('click',()=>openDevice(d,row));row.addEventListener('keydown',event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();openDevice(d,row)}});devices.append(row)}const events=$('#events');events.replaceChildren();if(!data.events.length)events.append(el('li','empty','新版本部署后将记录投递事件'));for(const e of data.events){const row=el('li','event '+(e.status==='failed'?'failed':''));const copy=el('div');copy.append(el('div','event-title',eventLabel(e.type)),el('div','event-meta',e.device_id+' · '+e.channel+' · '+e.environment));row.append(el('span','event-mark'),copy,el('time','event-time',relative(e.at)));events.append(row)}if(selectedDevice){const replacement=data.devices.find(device=>device.control_id===selectedDevice.control_id);if(replacement){selectedDevice=replacement;renderDevice(replacement)}else closeDevice()}}
    function detail(label,value){const card=el('div','detail');card.append(el('span','',label),el('strong','',value));return card}
    function renderDevice(d){$('#drawerTitle').textContent=d.id;$('#drawerSubtitle').textContent=(d.online?'云端在线':'等待心跳')+' · '+d.environment;$('#detailGrid').replaceChildren(detail('Agent 版本',d.agent_version||'—'),detail('最后心跳',d.heartbeat_age_seconds===null?'从未上报':d.heartbeat_age_seconds+' 秒前'),detail('蜂窝注册',stateLabel(d.cellular_state)),detail('信号强度',d.signal_dbm===null?'—':d.signal_dbm+' dBm'),detail('AT 通道',d.at_ok?'正常':'异常'),detail('USB ECM',d.ecm_carrier?'Carrier 正常':'Carrier 断开'),detail('注册时间',d.registered_at?new Date(d.registered_at).toLocaleString('zh-CN'):'—'),detail('APNs 环境',d.environment));const channels=$('#channelGrid');channels.replaceChildren();for(const [key,label] of [['iphone','iPhone CallKit'],['alert','通知 APNs'],['watch','Apple Watch'],['live_activity','实时活动']]){const channel=el('div','channel '+(d.push[key]?'on':''));channel.append(el('span','',label),el('span','',d.push[key]?'已就绪':'未配置'),el('i'));channels.append(channel)}$('#sendVirtualCall').disabled=!d.push.iphone;$('#formStatus').textContent=d.push.iphone?'内容不会写入 Relay 日志':'该设备未配置 VoIP Push，无法模拟来电'}
    function openDevice(d,source){selectedDevice=d;lastFocus=source||document.activeElement;renderDevice(d);$('#scrim').hidden=false;$('#drawer').hidden=false;document.body.style.overflow='hidden';requestAnimationFrame(()=>$('#closeDrawer').focus())}
    function closeDevice(){selectedDevice=undefined;$('#scrim').hidden=true;$('#drawer').hidden=true;document.body.style.overflow='';if(lastFocus&&document.contains(lastFocus))lastFocus.focus()}
    function showToast(message){clearTimeout(toastTimer);$('#toast').textContent=message;$('#toast').hidden=false;toastTimer=setTimeout(()=>{$('#toast').hidden=true},3200)}
    async function sendVirtualCall(event){event.preventDefault();if(!selectedDevice)return;const title=$('#callTitle').value.trim(),content=$('#callContent').value.trim();if(!title||!content){$('#formStatus').textContent='请填写来电标题和播报内容';return}const button=$('#sendVirtualCall');button.disabled=true;button.textContent='正在发送…';$('#formStatus').textContent='正在通过 APNs 投递';try{const response=await fetch('/dashboard/api/virtual-call',{method:'POST',headers:{authorization:'Bearer '+sessionStorage.getItem(tokenKey),'content-type':'application/json'},body:JSON.stringify({device_id:selectedDevice.control_id,title,content})});const type=response.headers.get('content-type')||'';const result=type.includes('application/json')?await response.json():{error:'Relay 暂时不可用（HTTP '+response.status+'），请稍后重试'};if(!response.ok)throw new Error(result.error||'发送失败');$('#formStatus').textContent='已送达 APNs，等待 iPhone 响铃';showToast('虚拟来电已发送到 '+selectedDevice.id)}catch(error){$('#formStatus').textContent=error.message}finally{button.disabled=!selectedDevice.push.iphone;button.textContent='模拟来电'}}
    $('#connect').addEventListener('click',()=>{const value=$('#token').value.trim();if(!value){$('#error').textContent='请输入 Dashboard Token。';return}sessionStorage.setItem(tokenKey,value);$('#error').textContent='';load().catch(e=>{$('#error').textContent=e.message})});$('#token').addEventListener('keydown',e=>{if(e.key==='Enter')$('#connect').click()});$('#refresh').addEventListener('click',()=>load().catch(e=>{$('#updated').textContent=e.message}));$('#lock').addEventListener('click',()=>{closeDevice();sessionStorage.removeItem(tokenKey);clearTimeout(timer);$('#token').value='';$('#login').hidden=false});$('#scrim').addEventListener('click',closeDevice);$('#closeDrawer').addEventListener('click',closeDevice);$('#virtualCallForm').addEventListener('submit',sendVirtualCall);document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!$('#drawer').hidden)closeDevice()});load().catch(e=>{$('#error').textContent=e.message;$('#login').hidden=false});
  </script>
</body>
</html>`;
}
