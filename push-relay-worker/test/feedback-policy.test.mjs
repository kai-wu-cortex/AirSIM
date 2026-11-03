import test from "node:test";
import assert from "node:assert/strict";
import { handleFeedback } from "../src/feedback.mjs";

const env = { NOTION_TOKEN: "fixture", NOTION_DATABASE_ID: "fixture" };
const request = (trigger) => new Request("https://example.invalid/v1/feedback", {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ feedback_id: "fixture", trigger, platform: "iOS" }),
});

test("non-manual feedback never uploads attachments or creates Notion pages", async () => {
  const original = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = async () => { requests++; throw new Error("unexpected outbound request"); };
  try {
    for (const trigger of [undefined, null, "", "periodic", "error", "call_ended", "sms_sent", "sms_received", "crash", "startup", "MANUAL", " manual "]) {
      const response = await handleFeedback(request(trigger), env);
      assert.equal(response.status, 403);
      assert.equal((await response.json()).error, "manual_feedback_required");
    }
    assert.equal(requests, 0);
  } finally { globalThis.fetch = original; }
});

test("manual feedback still reaches Notion through mocked network only", async () => {
  const original = globalThis.fetch;
  let pages = 0;
  globalThis.fetch = async (url, options) => {
    if (String(url).endsWith("/pages")) {
      pages++;
      assert.equal(JSON.parse(options.body).properties["触发方式"].select.name, "manual");
    }
    return Response.json({ id: "fixture-id", url: "https://example.invalid/feedback" });
  };
  try {
    const response = await handleFeedback(request("manual"), env);
    assert.equal(response.status, 200);
    assert.equal(pages, 1);
  } finally { globalThis.fetch = original; }
});
