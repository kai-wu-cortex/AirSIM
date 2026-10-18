import assert from "node:assert/strict";
import test from "node:test";
import { makeCommandHarness } from "./helpers/command-fixtures.mjs";

test("concurrent enqueue pins one immutable target and delivery", async () => {
  const h = makeCommandHarness();
  const {socket:a} = await h.connect("android-A");
  const {socket:b} = await h.connect("android-B");
  const command = {command_id:"c87f982a-1750-4f03-9a96-6553e454f522",type:"send_sms",number:"synthetic",message:"fixture",target_agent_id:"android-A",expires_at:new Date(Date.now()+60000).toISOString()};
  const replies = await Promise.all([h.enqueue(command),h.enqueue(command),h.enqueue({...command,target_agent_id:"android-B"})]);
  assert.deepEqual(replies.map(r=>r.status),[202,202,409]);
  assert.equal(a.sent.length,1);assert.equal(b.sent.length,0);
});

test("two named Agents coexist; replacing A and late A callbacks cannot affect B or new A", async () => {
  const h = makeCommandHarness();
  const {socket:a} = await h.connect("android-A");
  const {socket:b} = await h.connect("android-B");
  assert.equal(a.closed, false);
  const {socket:a2} = await h.connect("android-A");
  assert.equal(a.code,4001);
  assert.equal(b.closed,false);
  h.session.webSocketClose(a,1000,"closed");
  h.session.webSocketError(a);
  assert.equal(a2.closed,false);
  assert.equal(b.closed,false);
});
test("legacy collisions cool down rather than evict the live connection", async () => {
  const h = makeCommandHarness();
  const {socket:old} = await h.connect(null);
  const {response} = await h.connect(null);
  assert.equal(response.status,429);
  assert.equal(response.headers.get("retry-after"),"60");
  assert.equal(old.closed,false);
});
test("legacy and a named Agent called legacy never share a connection scope", async () => {
  const h = makeCommandHarness();
  const {socket:old} = await h.connect(null);
  await h.connect("legacy");
  assert.equal(old.closed,false);
});
test("Agent identifiers preserve URI and Unicode characters but reject controls and oversized UTF8", async () => {
  const h = makeCommandHarness();
  const {socket} = await h.connect("安卓:A/1?x");
  assert.equal(socket.deserializeAttachment().agent_id,"安卓:A/1?x");
  for(const id of ["", " A", "a\nb", "界".repeat(43)]) {
    const {response} = await h.connect(id);
    assert.equal(response.status,400);
  }
});

const command = (target="android-A") => ({command_id:"c87f982a-1750-4f03-9a96-6553e454f522",type:"dtmf",number:"1",
  target_agent_id:target,expires_at:new Date(Date.now()+60000).toISOString()});
test("A command stays with A through push pull alarm reconnect and completion", async () => {
  const h=makeCommandHarness();
  const {socket:b}=await h.connect("android-B");
  const c=command();
  assert.equal((await h.enqueue(c)).status,202);
  assert.equal(b.sent.length,0);
  assert.deepEqual((await h.pull("android-B")).commands,[]);
  assert.equal((await h.complete("android-B",{command_id:c.command_id,status:"completed"})).status,403);
  await h.session.alarm();
  assert.equal(b.sent.length,0);
  const {socket:a}=await h.connect("android-A");
  assert.equal(a.sent.length,1);
  assert.equal(a.sent[0].target_agent_id,"android-A");
  assert.equal((await h.enqueue({...c,target_agent_id:"android-B"})).status,409);
  assert.equal((await h.enqueue({...c,number:"2"})).status,409);
  assert.equal((await h.complete("android-A",{command_id:c.command_id,status:"completed"})).status,202);
  assert.equal((await h.complete("android-B",{command_id:c.command_id,status:"completed"})).status,403);
  await h.session.alarm();
  assert.equal(b.sent.length,0);
});
test("multiple unbound candidates reject; old records remain legacy and new named callers cannot steal them", async () => {
  const h=makeCommandHarness();
  await h.connect("android-A"); await h.connect("android-B");
  const c=command(); delete c.target_agent_id;
  assert.equal((await h.enqueue(c)).status,409);
  await h.storage.put(`command:${c.command_id}`,{command:c,status:"pending",expires_at_ms:Date.now()+60000});
  assert.deepEqual((await h.pull("android-A")).commands,[]);
  assert.equal((await h.pull(null)).commands.length,1);
});
test("socket completion uses its attachment, not a forged message agent", async () => {
  const h=makeCommandHarness(); const {socket:b}=await h.connect("android-B");
  const c=command(); await h.enqueue(c);
  await h.session.webSocketMessage(b,JSON.stringify({command_id:c.command_id,status:"completed",agent_id:"android-A"}));
  assert.equal((await h.storage.get(`command:${c.command_id}`)).status,"pending");
});
test("rescue hangup inherits A and never broadcasts to B", async () => {
  const h=makeCommandHarness(); const {socket:a}=await h.connect("android-A"),{socket:b}=await h.connect("android-B");
  const c={...command(),type:"call_control",action:"end"}; await h.enqueue(c);
  const record=await h.storage.get(`command:${c.command_id}`);record.rescue_due_at_ms=Date.now()-1;
  await h.storage.put(`command:${c.command_id}`,record); await h.session.alarm();
  assert.equal(b.sent.length,0);
  assert.ok(a.sent.some(x=>x.action==="rescue_hangup"&&x.target_agent_id==="android-A"));
});
