import test from 'node:test';
import assert from 'node:assert/strict';
import { nginxIPConfig } from '../configure-ip.mjs';

test('IP endpoint keeps APIs off plaintext and preserves HTTPS/WSS origin', () => {
  const bootstrap = nginxIPConfig('118.178.109.247');
  assert.match(bootstrap, /location \/ \{ return 404; \}/);
  assert.doesNotMatch(bootstrap, /proxy_pass|listen 443/);
  const config = nginxIPConfig('118.178.109.247', true);
  assert.match(config, /listen 443 ssl/);
  assert.match(config, /proxy_set_header Host 118\.178\.109\.247;/);
  assert.match(config, /proxy_set_header X-Forwarded-Proto https;/);
  assert.match(config, /proxy_set_header Upgrade \$http_upgrade;/);
  assert.match(config, /access_log off;/);
  assert.doesNotMatch(config, /8789|8790/);
  assert.throws(() => nginxIPConfig('example.com; injected {}'));
});
