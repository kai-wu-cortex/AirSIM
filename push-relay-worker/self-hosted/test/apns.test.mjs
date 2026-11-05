import test from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { once } from 'node:events';
import { createAPNsBridge } from '../apns-bridge.mjs';
import { mkdtemp, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

test('APNs service starts when invoked through a release symlink', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'airsim-apns-link-'));
  const link = join(dir, 'apns-bridge.mjs');
  await symlink(resolve('apns-bridge.mjs'), link);
  const reserve = net.createServer().listen(0, '127.0.0.1');
  await once(reserve, 'listening'); const port = reserve.address().port;
  await new Promise(r => reserve.close(r));
  const child = spawn(process.execPath, [link], { env: { ...process.env, APNS_BRIDGE_PORT: String(port) }, stdio: 'pipe' });
  t.after(async () => {
    if (child.exitCode === null) { const exited = once(child, 'exit'); child.kill('SIGTERM'); await exited; }
    await rm(dir, { recursive: true, force: true });
  });
  for (let i = 0; i < 100; i++) {
    assert.equal(child.exitCode, null, 'service must not exit without opening listener');
    try { assert.equal((await fetch(`http://127.0.0.1:${port}/`)).status, 400); return; } catch {}
    await delay(20);
  }
  assert.fail('bridge did not start');
});

test('APNs bridge uses HTTP/2, preserves errors, rejects arbitrary destinations, never replays', async t => {
  const upstream = http2.createServer(); let requests = 0;
  upstream.on('stream', (stream, headers) => {
    requests++;
    assert.equal(headers[':method'], 'POST');
    assert.equal(headers.authorization, 'bearer synthetic');
    assert.equal(headers['apns-topic'], 'com.example.airsim.voip');
    assert.equal(headers['x-airsim-apns-origin'], undefined);
    stream.on('data', () => {});
    stream.on('end', () => { stream.respond({ ':status': 400, 'apns-id': 'synthetic' }); stream.end('{"reason":"BadDeviceToken"}'); });
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  const bridge = createAPNsBridge({ connect(origin) {
    assert.equal(origin, 'https://api.sandbox.push.apple.com');
    return http2.connect(`http://127.0.0.1:${upstream.address().port}`);
  } });
  bridge.server.listen(0, '127.0.0.1'); await once(bridge.server, 'listening');
  t.after(async () => { await bridge.close(); await new Promise(r => upstream.close(r)); });
  const url = `http://127.0.0.1:${bridge.server.address().port}/3/device/${'a'.repeat(64)}`;
  const headers = { 'x-airsim-apns-origin': 'https://api.sandbox.push.apple.com', authorization: 'bearer synthetic', 'apns-topic': 'com.example.airsim.voip' };
  const response = await fetch(url, { method: 'POST', headers, body: '{"aps":{}}' });
  assert.equal(response.status, 400); assert.equal((await response.json()).reason, 'BadDeviceToken');
  assert.equal(response.headers.get('apns-id'), 'synthetic');
  assert.equal((await fetch(url, { method: 'POST', headers: { ...headers, 'x-airsim-apns-origin': 'http://169.254.169.254' } })).status, 400);
  assert.equal((await fetch(url, { method: 'POST', headers, body: 'x'.repeat(4097) })).status, 413);
  assert.equal(requests, 1);
});
