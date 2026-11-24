import assert from "node:assert/strict";
import test from "node:test";
import { readAgentHeartbeatsFromKV } from "../src/status-store.mjs";

test("KV roster loads every page instead of truncating at 100 devices", async () => {
  const records = Array.from({length: 237}, (_, i) => ({ agent_id: `agent-${i}` }));
  const cursors = [];
  const env = { DEVICES: {
    async list({prefix, limit, cursor}) {
      assert.equal(prefix, "heartbeat:phone:agent:");
      assert.equal(limit, 100);
      const start = Number(cursor ?? 0);
      cursors.push(start);
      return { keys: records.slice(start, start + limit).map((_, i) => ({name: String(start + i)})),
        list_complete: start + limit >= records.length, cursor: String(start + limit) };
    },
    async get(key) { return JSON.stringify(records[Number(key)]); },
  }};
  const actual = await readAgentHeartbeatsFromKV(env, "phone");
  assert.deepEqual(actual, records);
  assert.deepEqual(cursors, [0, 100, 200]);
});

test("an empty KV page with a continuation cursor does not hide later devices", async () => {
  const env = { DEVICES: {
    async list({cursor}) { return cursor ? {keys:[{name:"last"}], list_complete:true}
      : {keys:[],list_complete:false,cursor:"next"}; },
    async get() { return JSON.stringify({agent_id:"last"}); },
  }};
  assert.deepEqual(await readAgentHeartbeatsFromKV(env, "phone"), [{agent_id:"last"}]);
});
