// Hosting adapter only. The Cloudflare Relay sources remain shared and unchanged.
import { WorkerEntrypoint } from 'cloudflare:workers';
import relay from '../src/index.mjs';
export { CallMediaSession, DeviceCommandSession, AgentStatusRegistry } from '../src/index.mjs';
export { LocalKV } from './kv.mjs';
import { kvBinding } from './kv.mjs';

function bindings(env) { return { ...env, DEVICES: kvBinding(env.KV_STORE) }; }

export default {
  fetch(request, env, ctx) { return relay.fetch(request, bindings(env), ctx); },
};

// Only exposed on a separate loopback socket. Never proxy this port publicly.
export class Maintenance extends WorkerEntrypoint {
  async fetch(request) {
    if (request.method !== 'POST' || new URL(request.url).pathname !== '/scheduled') {
      return new Response('not found', { status: 404 });
    }
    const jobs = [];
    await relay.scheduled({}, bindings(this.env), { waitUntil(job) { jobs.push(job); } });
    await Promise.all(jobs);
    return Response.json({ ok: true });
  }
}
