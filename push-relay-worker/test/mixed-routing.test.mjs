import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { makeCommandHarness } from "./helpers/command-fixtures.mjs";

globalThis.crypto ??= webcrypto;
const command = {command_id:"c87f982a-1750-4f03-9a96-6553e454f522",type:"send_sms",number:"synthetic",message:"fixture",expires_at:new Date(Date.now()+60000).toISOString()};

test("legacy client resolves only one scope; multiple named agents fail closed", async () => {
  const legacy = makeCommandHarness();
  const {socket} = await legacy.connect(null);
  assert.equal((await legacy.enqueue(command)).status,202);
  assert.equal(socket.sent.length,1);
  const multiple=makeCommandHarness();
  await multiple.connect("A");await multiple.connect("B");
  assert.equal((await multiple.enqueue(command)).status,409);
});

test("separate Apple device objects never share a same-named Android queue", async () => {
  const apple1=makeCommandHarness(),apple2=makeCommandHarness();
  const {socket:a}=await apple1.connect("same-agent");
  const {socket:b}=await apple2.connect("same-agent");
  assert.equal((await apple1.enqueue({...command,target_agent_id:"same-agent"})).status,202);
  assert.equal(a.sent.length,1);assert.equal(b.sent.length,0);
  assert.deepEqual((await apple2.pull("same-agent")).commands,[]);
});

test("actual pre-routing Relay rejects v2 clients without executing v1 actions", async () => {
  // Read-only compatibility fixture: import the real baseline router, not a guessed mock.
  const source=execFileSync("git",["show","04253964092aeef5f2ddfe34e59bfb15d8d828fd:push-relay-worker/src/index.mjs"],{encoding:"utf8"})
    .replaceAll(/from "(\.\/[^"\n]+)"/g,(_,path)=>`from "${new URL(path,new URL("../src/index.mjs",import.meta.url)).href}"`);
  const old=(await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)).default;
  let actions=0;
  const env={COMMANDS:{get(){actions++;throw Error("unsafe fallback");}},REGISTRATIONS:{get(){actions++;throw Error("unsafe fallback");}}};
  const enqueue=await old.fetch(new Request("https://relay.example/v2/commands/enqueue",{method:"POST",body:JSON.stringify({...command,target_agent_id:"A"})}),env);
  assert.equal(enqueue.status,404);
  const connect=await old.fetch(new Request("https://relay.example/v2/devices/apple-test/commands/connect?agent_id=A",{headers:{upgrade:"websocket"}}),env);
  assert.equal(connect.status,405);
  assert.equal(actions,0);
});
