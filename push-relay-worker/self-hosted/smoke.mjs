// Run on ECS, or explicitly select an HTTPS origin for external verification.
// Only synthetic devices; no real push,
// phone call or SMS is sent. Only this run's own registration is deleted.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHmac, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import http2 from 'node:http2';

const config = JSON.parse(readFileSync(process.env.AIRSIM_SMOKE_CONFIG || '/etc/airsim-relay/config.json', 'utf8'));
const origin = process.env.AIRSIM_SMOKE_ORIGIN || 'http://127.0.0.1:8787';
const originURL = new URL(origin);
assert.ok(originURL.protocol === 'https:' || (originURL.protocol === 'http:' && originURL.hostname === '127.0.0.1'), 'Remote smoke requires verified HTTPS');
const auth = { device_id: 'ecs-smoke-' + randomUUID(), device_secret: randomUUID() };
const admin = { authorization: 'Bearer ' + config.DASHBOARD_TOKEN };
const sockets = [];
const post = (path, data) => fetch(origin + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(data), signal: AbortSignal.timeout(10000) });
async function socket(url) {
  const ws = new WebSocket(url); ws.binaryType = 'arraybuffer'; ws.frames = []; sockets.push(ws);
  ws.addEventListener('message', event => { if (event.data instanceof ArrayBuffer) ws.frames.push(new Uint8Array(event.data)); });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('socket open timeout')), 5000);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('socket failed')); }, { once: true });
  });
  return ws;
}
try {
  assert.equal((await fetch(origin + '/healthz')).status, 200);
  assert.equal((await fetch(origin + '/dashboard/api/summary')).status, 401);
  assert.equal((await post('/v1/devices/register', { ...auth, voip_token: 'a'.repeat(64), bundle_id: config.ALLOWED_BUNDLE_ID, environment: 'sandbox', relay_url: 'https://relay.example' })).status, 200);
  assert.equal((await post('/v1/events/heartbeat', { ...auth, event: 'agent_heartbeat', agent_id: 'synthetic', at_ok: true, cellular_state: 'registered' })).status, 202);
  assert.equal((await post('/v1/devices/status', auth)).status, 200);
  assert.equal((await post('/v1/devices/status', { ...auth, device_secret: 'wrong' })).status, 401);
  const command = { ...auth, command_id: randomUUID(), type: 'dial', number: '123456', target_agent_id: 'synthetic' };
  const r = await post('/v2/commands/enqueue', command); assert.equal(r.status, 202);
  const first = await r.json();
  const duplicate = await (await post('/v2/commands/enqueue', command)).json();
  assert.equal(duplicate.duplicate, true); assert.equal(duplicate.call.call_uuid, first.call.call_uuid);
  const url = `${first.call.media_url}?token=${first.call.call_secret}`;
  assert.equal(new URL(url).host, originURL.host);
  assert.equal(new URL(url).protocol, originURL.protocol === 'https:' ? 'wss:' : 'ws:');
  const agent = await socket(url + '&role=agent'); const iphone = await socket(url + '&role=iphone');
  iphone.send(JSON.stringify({ action: 'answer' }));
  // Each socket preserves message order: answer precedes its PCM packet.
  iphone.send(new Uint8Array([5,6,7,8])); agent.send(new Uint8Array([1,2,3,4]));
  for (let i = 0; i < 100 && (!agent.frames.length || !iphone.frames.length); i++) await delay(20);
  assert.deepEqual([...agent.frames[0]], [5,6,7,8]); assert.deepEqual([...iphone.frames[0]], [1,2,3,4]);
  console.log('PASS: health, dashboard auth, registration, heartbeat, device auth, command dedup, bidirectional binary PCM');
} finally {
  for (const s of sockets) s.close();
  const control = createHmac('sha256', config.DASHBOARD_TOKEN).update(auth.device_id).digest('hex').slice(0,32);
  const cleanup = await fetch(origin + '/dashboard/api/devices/' + control, { method: 'DELETE', headers: admin, signal: AbortSignal.timeout(10000) });
  assert.ok([200,404].includes(cleanup.status));
  console.log('Synthetic registration removed');
}

for (const host of (process.env.AIRSIM_SMOKE_ORIGIN ? [] : ['api.push.apple.com', 'api.sandbox.push.apple.com'])) {
  await new Promise(resolve => {
    const session = http2.connect('https://' + host);
    const timer = setTimeout(() => finish('TIMEOUT'), 12000);
    let done = false;
    function finish(result) { if (done) return; done = true; clearTimeout(timer); console.log(host + ': ' + result); session.destroy(); resolve(); }
    session.on('error', () => finish('CONNECTION_FAILED'));
    session.on('connect', () => {
      const req = session.request({ ':method': 'GET', ':path': '/' });
      req.on('response', h => finish('TLS verified, ALPN=' + session.alpnProtocol + ', HTTP=' + h[':status']));
      req.on('error', () => finish('REQUEST_FAILED'));
      req.resume(); req.end();
    });
  });
}
console.log('Configuration presence:', JSON.stringify({ APNS_P8: Boolean(config.APNS_P8), NOTION_TOKEN: Boolean(config.NOTION_TOKEN), NOTION_DATABASE_ID: Boolean(config.NOTION_DATABASE_ID) }));
