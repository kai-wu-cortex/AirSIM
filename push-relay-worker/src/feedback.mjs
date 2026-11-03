const NOTION_VERSION = "2022-06-28";
const MAX_FEEDBACK_BYTES = 1024 * 1024;
const PCM_MODES = [
  "vowlan_direct_full_duplex", "vowlan_direct_downlink_only",
  "vowlan_direct_uplink_only", "vowlan_direct_silent",
  "voble_ble_full_duplex", "voble_ble_uplink_only",
  "cloud_relay_full_duplex", "cloud_relay_downlink_only",
  "cloud_relay_silent", "not_connected", "unknown",
];

function json(status, value) {
  return new Response(JSON.stringify(value) + "\n", {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
    },
  });
}

function text(value, limit = 1900) {
  return String(value ?? "").slice(0, limit);
}

function rich(value) {
  // Notion rich_text has a 2000-character limit per text object.
  const content = text(value).slice(0, 1900);
  return content ? { rich_text: [{ text: { content } }] } : { rich_text: [] };
}

function select(value, allowed) {
  const name = String(value ?? "");
  return { select: allowed.includes(name) ? { name } : null };
}

function multiSelect(values, allowed) {
  const names = Array.isArray(values) ? values : [];
  return {
    multi_select: [...new Set(names)]
      .filter((name) => allowed.includes(String(name)))
      .map((name) => ({ name: String(name) })),
  };
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? { number: parsed } : { number: null };
}

function fileBlocks(label, value) {
  const source = String(value ?? "").trim();
  if (!source) return [];
  const chunks = [];
  for (let index = 0; index < source.length && chunks.length < 40; index += 1800) {
    chunks.push(source.slice(index, index + 1800));
  }
  return chunks.map((chunk, index) => ({
    object: "block",
    type: "code",
    code: {
      rich_text: [{ type: "text", text: { content: chunk } }],
      language: "plain text",
      caption: [{ type: "text", text: { content: label + (chunks.length > 1 ? " " + (index + 1) + "/" + chunks.length : "") } }],
    },
  }));
}

function fileProperty(id) {
  return id ? { files: [{ type: "file_upload", file_upload: { id } }] } : { files: [] };
}

function buildProperties(body, files = {}) {
  const pcm = body.pcm && typeof body.pcm === "object" ? body.pcm : {};
  const audio = body.audio && typeof body.audio === "object" ? body.audio : {};
  const audioStages = ["answer_observed", "phone_start", "engine_ready", "agent_register",
    "pcm_ready", "first_downlink", "agent_ready", "stopped", "failed"];
  const pcmMode = PCM_MODES.includes(String(pcm.mode)) ? String(pcm.mode) : "unknown";
  const platform = ["iOS", "Android", "Both"].includes(body.platform) ? body.platform : "Both";
  const triggers = ["periodic", "manual", "error", "call_ended", "sms_sent", "sms_received"];
  const trigger = triggers.includes(body.trigger) ? body.trigger : "manual";
  const mode = ["auto", "vowlan", "voble", "cloud", "offline"].includes(body.connection_mode)
    ? body.connection_mode : "offline";
  const relay = ["online", "offline", "unknown"].includes(body.relay_status)
    ? body.relay_status : "unknown";
  const capture = ["observed", "all_zero", "unverified"].includes(pcm.capture)
    ? pcm.capture : "unverified";
  return {
    "名称": { title: [{ text: { content: text(body.feedback_id || "AirSIM " + new Date().toISOString(), 120) } }] },
    "反馈 ID": rich(body.feedback_id),
    "提交时间": { date: { start: new Date().toISOString() } },
    "触发方式": select(trigger, triggers),
    "平台": select(platform, ["iOS", "Android", "Both"]),
    "App 版本": rich(body.app_version),
    "iOS 版本": rich(body.ios_version),
    "iPhone 型号": rich(body.iphone_model),
    "Android 型号": rich(body.android_model),
    "Android SDK": number(body.android_sdk),
    "连接模式": select(mode, ["auto", "vowlan", "voble", "cloud", "offline"]),
    "当前路由": rich(body.route),
    "Relay 状态": select(relay, ["online", "offline", "unknown"]),
    "PCM 连接模式": select(pcmMode, PCM_MODES),
    "PCM 路由": rich(pcm.route),
    "PCM 采集源": rich(pcm.capture_source),
    "PCM 初始化": { checkbox: pcm.initialized === true },
    "PCM 路由验证": { checkbox: pcm.route_verified === true },
    "PCM 采集状态": select(capture, ["observed", "all_zero", "unverified"]),
    "PCM 下行峰值": number(pcm.down_peak),
    "PCM 上行峰值": number(pcm.up_peak),
    "PCM 下行字节": number(pcm.down_bytes),
    "PCM 上行字节": number(pcm.up_bytes),
    "PCM 失败原因": rich(pcm.failure),
    "音频启动阶段": multiSelect(audio.stages, audioStages),
    "音频启动耗时": number(audio.startup_ms),
    "音频启动缺失": multiSelect(audio.missing, audioStages),
    "PCM 客户端关闭": { checkbox: audio.pcm_client_closed === true },
    "Telecom 状态": rich(audio.telecom_state),
    "音频诊断": rich(audio.summary),
    "崩溃诊断": rich(body.crash),
    "iOS 日志": fileProperty(files.ios),
    "Android 日志": fileProperty(files.android),
    "结构化 JSON": fileProperty(files.json),
    "错误摘要": rich(body.error_summary),
    "用户描述": rich(body.description),
    "备注": rich(body.remark),
    "处理状态": select("新反馈", ["新反馈", "处理中", "已解决"]),
  };
}

async function uploadNotionFile(env, filename, content, contentType) {
  const source = String(content ?? "");
  if (!source.trim()) return "";
  const created = await notionRequest(env, "file_uploads", "POST", {
    filename,
    content_type: contentType,
  });
  if (!created.id || !created.upload_url) throw new Error("notion file upload was not created");
  const form = new FormData();
  form.append("file", new Blob([source], { type: contentType }), filename);
  const response = await fetch(created.upload_url, {
    method: "POST",
    headers: {
      authorization: "Bearer " + env.NOTION_TOKEN,
      "notion-version": NOTION_VERSION,
    },
    body: form,
  });
  if (!response.ok) throw new Error("notion file send failed HTTP " + response.status);
  return created.id;
}

async function notionRequest(env, path, method, body) {
  const response = await fetch("https://api.notion.com/v1/" + path, {
    method,
    headers: {
      authorization: "Bearer " + env.NOTION_TOKEN,
      "notion-version": NOTION_VERSION,
      "content-type": "application/json",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = typeof payload.message === "string" ? payload.message : "notion HTTP " + response.status;
    throw new Error(message.slice(0, 300));
  }
  return payload;
}

export async function handleFeedback(request, env) {
  if (!env.NOTION_TOKEN || !env.NOTION_DATABASE_ID) {
    return json(503, { error: "notion feedback is not configured" });
  }
  const declared = Number(request.headers.get("content-length") || "0");
  if (declared > MAX_FEEDBACK_BYTES) return json(413, { error: "feedback too large" });
  let body;
  try {
    body = await request.json();
  } catch {
    return json(400, { error: "invalid JSON" });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return json(400, { error: "invalid feedback" });
  }
  if (JSON.stringify(body).length > MAX_FEEDBACK_BYTES) {
    return json(413, { error: "feedback too large" });
  }
  // Reject legacy automatic triggers before uploading attachments or creating pages.
  // This is a product policy, not authentication/proof of a human click.
  if (body.trigger !== "manual") {
    return json(403, { error: "manual_feedback_required" });
  }

  try {
    const files = {};
    try {
      files.ios = await uploadNotionFile(env, "airsim-ios-" + (body.feedback_id || "feedback") + ".txt",
        body.ios_trace, "text/plain");
      files.android = await uploadNotionFile(env, "airsim-android-" + (body.feedback_id || "feedback") + ".txt",
        body.android_log, "text/plain");
      files.json = await uploadNotionFile(env, "airsim-feedback-" + (body.feedback_id || "feedback") + ".json",
        JSON.stringify(body, null, 2), "application/json");
    } catch (error) {
      console.error("notion feedback attachment failed", String(error && error.message ? error.message : error).slice(0, 300));
    }
    const page = await notionRequest(env, "pages", "POST", {
      parent: { database_id: env.NOTION_DATABASE_ID },
      properties: buildProperties(body, files),
      children: [
        ...fileBlocks("iOS Verbose", body.ios_trace),
        ...fileBlocks("Android BridgeLog", body.android_log),
      ],
    });
    return json(200, { ok: true, page_id: page.id, url: page.url || "" });
  } catch (error) {
    console.error("notion feedback failed", String(error && error.message ? error.message : error).slice(0, 300));
    return json(502, { error: "notion write failed" });
  }
}
