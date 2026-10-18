import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { readdirSync } from "node:fs";
import { join } from "node:path";

// Uses only an ephemeral local workerd instance; no credentials or production traffic.
const {Miniflare,convertV4MiniflareOptions} = await import(process.env.AIRSIM_MINIFLARE_MODULE || "miniflare");
const sourceRoot=fileURLToPath(new URL("../src/",import.meta.url));
const options = {
  modulesRoot:sourceRoot,
  modules:["index.mjs",...readdirSync(sourceRoot).filter(f=>f.endsWith(".mjs") && f!=="index.mjs")]
    .map(f=>({type:"ESModule",path:join(sourceRoot,f)})),
  compatibilityDate:"2026-08-01",
  durableObjects:{COMMANDS:{className:"DeviceCommandSession",useSQLite:true}},
};
const runtime = new Miniflare(convertV4MiniflareOptions ? convertV4MiniflareOptions(options) : options);
const sockets=[];
try {
  const env=await runtime.getBindings();
  const stub=env.COMMANDS.get(env.COMMANDS.idFromName("synthetic-device"));
  async function connect(agent) {
    const response=await stub.fetch("https://internal/connect",{headers:{upgrade:"websocket","x-airsim-agent-id":encodeURIComponent(agent)}});
    assert.equal(response.status,101);
    const socket=response.webSocket;socket.accept();sockets.push(socket);
    const messages=[];socket.addEventListener("message",e=>messages.push(JSON.parse(e.data)));
    return {socket,messages};
  }
  const a=await connect("安卓-A/slot?%"),b=await connect("android-B");
  const command={command_id:"c87f982a-1750-4f03-9a96-6553e454f522",type:"send_sms",number:"synthetic",message:"fixture",target_agent_id:"安卓-A/slot?%",expires_at:new Date(Date.now()+60000).toISOString()};
  const enqueue=c=>stub.fetch("https://internal/enqueue",{method:"POST",body:JSON.stringify(c)});
  const responses=await Promise.all([enqueue(command),enqueue(command),enqueue({...command,target_agent_id:"android-B"})]);
  assert.deepEqual(responses.map(r=>r.status),[202,202,409]);
  const pull=await stub.fetch("https://internal/pending",{method:"POST",headers:{"x-airsim-agent-id":"android-B"}});
  assert.deepEqual((await pull.json()).commands,[]);
  const complete=await stub.fetch("https://internal/complete",{method:"POST",headers:{"x-airsim-agent-id":"android-B"},body:JSON.stringify({command_id:command.command_id,status:"completed"})});
  assert.equal(complete.status,403);
  assert.equal(b.messages.length,0);
  assert.equal(a.messages.length,1);
  const replacement=await connect("安卓-A/slot?%");
  assert.equal(replacement.messages.length<=1,true);
  assert.equal(b.socket.readyState,1);
  console.log("Local workerd routing integration passed: coexistence, concurrent dedup, wrong-agent pull/completion, replacement isolation");
} finally {
  for(const socket of sockets) try {socket.close(1000,"test done");}catch{}
  await runtime.dispose();
}
