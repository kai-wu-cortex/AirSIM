import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import net from 'node:net';
import http from 'node:http';
import { generateKeyPairSync } from 'node:crypto';
import WebSocket from 'ws';
import { generateConfig } from '../configure.mjs';
import { LocalKV } from '../kv.mjs';

async function freePort() {
  const server = net.createServer().listen(0, '127.0.0.1');
  await once(server, 'listening'); const port = server.address().port;
  await new Promise(r => server.close(r)); return port;
}

test('real workerd: auth, heartbeat, command dedup/routing, duplex PCM, persistent restart, cron isolation', { timeout: 40000 }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'airsim-host-test-'));
  const dataDir = join(dir, 'data'); await mkdir(dataDir);
  const [httpPort, maintenancePort, apnsPort] = await Promise.all([freePort(), freePort(), freePort()]);
  const origin = `http://127.0.0.1:${httpPort}`;
  const pushRequests = [];
  const apns = http.createServer(async (req, res) => { const chunks = []; for await (const b of req) chunks.push(b); pushRequests.push({ headers: req.headers, payload: JSON.parse(Buffer.concat(chunks)) }); res.writeHead(200).end(); });
  apns.listen(apnsPort, '127.0.0.1'); await once(apns, 'listening');
  t.after(() => new Promise(r => { apns.closeAllConnections(); apns.close(r); }));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const config = { APNS_TEAM_ID: 'synthetic-team', APNS_KEY_ID: 'synthetic-key', APNS_P8: privateKey.export({ type: 'pkcs8', format: 'pem' }), DASHBOARD_TOKEN: 'test-only-'.repeat(8), ALLOWED_BUNDLE_ID: 'com.example.airsim' };
  const configPath = join(dir, 'config.capnp');
  await writeFile(configPath, generateConfig({ config, dataDir, httpPort, maintenancePort, apnsPort }));
  let child, logs = '', sockets = [];
  async function start() {
    child = spawn(resolve('node_modules/.bin/workerd'), ['serve', configPath], { stdio: ['ignore','pipe','pipe'] });
    child.stdout.on('data', b => { logs += b; }); child.stderr.on('data', b => { logs += b; });
    for (let i = 0; i < 100; i++) {
      if (child.exitCode !== null) throw new Error('workerd exited: ' + logs);
      try { if ((await fetch(origin + '/healthz')).ok) return; } catch {}
      await delay(50);
    }
    throw new Error('workerd not ready: ' + logs);
  }
  async function stop() {
    for (const s of sockets) s.terminate(); sockets = [];
    if (child && child.exitCode === null) { const exit = once(child, 'exit'); child.kill('SIGTERM'); const timer = setTimeout(() => child.kill('SIGKILL'), 1500); await exit; clearTimeout(timer); }
  }
  t.after(async () => { await stop(); await rm(dir, { recursive: true, force: true }); });
  const post = (path, value, headers = {}) => fetch(origin + path, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(value) });
  const auth = { device_id: 'synthetic-selfhost', device_secret: 's'.repeat(32) };
  const reg = { ...auth, voip_token: 'a'.repeat(64), bundle_id: config.ALLOWED_BUNDLE_ID, environment: 'sandbox', relay_url: 'https://relay.example' };
  async function socket(path, options) {
    const ws = new WebSocket(origin.replace('http:', 'ws:') + path, options); sockets.push(ws);
    ws.messages = [];
    ws.on('message', (data, binary) => ws.messages.push({ data, binary }));
    await once(ws, 'open'); return ws;
  }
  async function until(check) { for (let i = 0; i < 100; i++) { if (check()) return; await delay(20); } assert.fail('event missing: ' + logs); }
  await start();
  assert.equal((await fetch(origin + '/dashboard')).status, 200);
  assert.equal((await fetch(origin + '/dashboard/api/summary')).status, 401);
  assert.equal((await post('/scheduled', {})).status, 404);
  assert.equal((await post('/v1/devices/register', reg)).status, 200);
  assert.equal((await post('/v1/devices/register', { ...reg, device_secret: 'wrong'.repeat(10) })).status, 401);
  const heartbeat = { ...auth, event: 'agent_heartbeat', agent_id: 'synthetic-agent', at_ok: true, cellular_state: 'registered' };
  assert.equal((await post('/v1/events/heartbeat', heartbeat)).status, 202);
  const agentCommands = await socket('/v2/devices/synthetic-selfhost/commands/connect?agent_id=synthetic-agent', { headers: { Authorization: 'Bearer ' + auth.device_secret } });
  const command = { ...auth, command_id: 'c87f982a-1750-4f03-9a96-6553e454f522', type: 'dial', number: '123456', target_agent_id: 'synthetic-agent' };
  const first = await post('/v2/commands/enqueue', command, { 'x-forwarded-proto': 'https' });
  assert.equal(first.status, 202); const result = await first.json();
  assert.match(result.call.media_url, /^wss:/);
  const duplicate = await (await post('/v2/commands/enqueue', command)).json();
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.call.call_uuid, result.call.call_uuid);
  await until(() => agentCommands.messages.length === 1);
  const path = `/v1/calls/${result.call.call_uuid}/connect?token=${result.call.call_secret}`;
  const agent = await socket(path + '&role=agent');
  const iphone = await socket(path + '&role=iphone');
  iphone.send(JSON.stringify({ action: 'answer' }));
  await until(() => agent.messages.some(m => !m.binary && m.data.toString().includes('answer')));
  agent.send(Buffer.from([1,2,3,4])); iphone.send(Buffer.from([5,6,7,8]));
  await until(() => iphone.messages.some(m => m.binary) && agent.messages.some(m => m.binary));
  assert.deepEqual(iphone.messages.find(m => m.binary).data, Buffer.from([1,2,3,4]));
  assert.deepEqual(agent.messages.find(m => m.binary).data, Buffer.from([5,6,7,8]));
  const incoming = await post('/v1/events/call', { ...auth, event: 'incoming_call', call_id: 'synthetic-incoming', call_uuid: 'd9b59660-05bb-4ea8-9aeb-4505b35c93f9', call_secret: 'synthetic-0123456789abcdef0123456789', number: '123456', issued_at: new Date().toISOString(), expires_at: new Date(Date.now() + 45000).toISOString() });
  assert.equal(incoming.status, 202);
  assert.equal(pushRequests.length, 1);
  assert.equal(pushRequests[0].headers['x-airsim-apns-origin'], 'https://api.sandbox.push.apple.com');
  assert.equal(pushRequests[0].headers['apns-push-type'], 'voip');
  assert.equal(pushRequests[0].payload.call_id, 'synthetic-incoming');
  // No real device is registered or dialled; only synthetic sockets on loopback.
  await stop(); await start();
  assert.equal((await post('/v1/devices/register', { ...reg, device_secret: 'wrong'.repeat(10) })).status, 401);
  const after = await (await post('/v2/commands/enqueue', command)).json();
  assert.equal(after.duplicate, true);
  assert.equal(after.call.call_uuid, result.call.call_uuid);
  assert.equal((await fetch(`http://127.0.0.1:${maintenancePort}/scheduled`, { method: 'POST' })).status, 200);
});

test('local KV filters TTLs, paginates live keys and deletes expired values', async () => {
  const values = new Map(); let alarm;
  const kv = new LocalKV({ storage: {
    get: async k => values.get(k), put: async (k,v) => values.set(k,v), delete: async k => values.delete(k),
    getAlarm: async () => alarm, setAlarm: async at => { alarm = at; },
    list: async ({ prefix = '', startAfter = '', limit = 1000 }) => new Map([...values].sort(([a],[b]) => a.localeCompare(b)).filter(([k]) => k.startsWith(prefix) && k > startAfter).slice(0,limit)),
  } });
  const call = async (op, args) => (await kv.fetch(new Request('https://kv/' + op, { method: 'POST', body: JSON.stringify(args) }))).json();
  await call('put', { key: 'a', value: 'expired', expiration: 1 });
  await call('put', { key: 'b', value: 'one' }); await call('put', { key: 'c', value: 'two' });
  const page = await call('list', { limit: 1 });
  assert.deepEqual(page.keys, [{ name: 'b' }]); assert.equal(page.list_complete, false);
  assert.deepEqual((await call('list', { limit: 1, cursor: page.cursor })).keys, [{ name: 'c' }]);
  assert.equal((await call('get', { key: 'a' })).value, null);
  assert.equal(values.has('a'), false);
  assert.equal((await call('get', { key: 'missing' })).value, null);
});
