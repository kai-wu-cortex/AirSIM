// The subset of Workers KV used by this Relay, backed by a private SQLite DO.
// No public route exposes this object; TTL filtering also applies to listing.
export function kvBinding(namespace) {
  const stub = namespace.get(namespace.idFromName('devices-v1'));
  async function call(op, value) {
    const response = await stub.fetch('https://kv.internal/' + op, {
      method: 'POST', body: JSON.stringify(value),
    });
    if (!response.ok) throw new Error('local KV operation failed');
    return response.json();
  }
  return {
    async get(key, type) {
      const { value } = await call('get', { key });
      return value !== null && (type === 'json' || type?.type === 'json') ? JSON.parse(value) : value;
    },
    async put(key, value, options = {}) { await call('put', { key, value, ...options }); },
    async delete(key) { await call('delete', { key }); },
    list(options = {}) { return call('list', options); },
  };
}

export class LocalKV {
  constructor(state) { this.storage = state.storage; }
  async fetch(request) {
    const args = await request.json();
    const op = new URL(request.url).pathname;
    if (op === '/put') {
      if (typeof args.key !== 'string' || typeof args.value !== 'string') return new Response(null, { status: 400 });
      const expiration = Number.isFinite(args.expiration) ? args.expiration * 1000
        : Number.isFinite(args.expirationTtl) ? Date.now() + args.expirationTtl * 1000 : null;
      await this.storage.put(args.key, { value: args.value, expiration });
      // Bounded periodic cleanup keeps expired state from accumulating on disk.
      if (!(await this.storage.getAlarm())) await this.storage.setAlarm(Date.now() + 3600_000);
      return Response.json({ ok: true });
    }
    if (op === '/get') {
      const item = await this.storage.get(args.key);
      if (item?.expiration !== null && item?.expiration <= Date.now()) {
        await this.storage.delete(args.key);
        return Response.json({ value: null });
      }
      return Response.json({ value: item?.value ?? null });
    }
    if (op === '/delete') {
      await this.storage.delete(args.key);
      return Response.json({ ok: true });
    }
    if (op === '/list') {
      const prefix = typeof args.prefix === 'string' ? args.prefix : '';
      const limit = Math.max(1, Math.min(1000, Number(args.limit) || 1000));
      let startAfter = args.cursor || undefined;
      const keys = [];
      // Read past expired entries so a page can still contain `limit` live keys.
      while (keys.length <= limit) {
        const batch = await this.storage.list({ prefix, ...(startAfter ? { startAfter } : {}), limit: limit + 1 });
        if (!batch.size) break;
        for (const [name, item] of batch) {
          startAfter = name;
          if (item.expiration !== null && item.expiration <= Date.now()) continue;
          keys.push({ name, ...(item.expiration !== null ? { expiration: item.expiration / 1000 } : {}) });
          if (keys.length > limit) break;
        }
        if (batch.size < limit + 1) break;
      }
      const complete = keys.length <= limit;
      return Response.json({ keys: keys.slice(0, limit), list_complete: complete,
        cursor: complete ? '' : keys[limit - 1].name });
    }
    return new Response(null, { status: 404 });
  }
  async alarm() {
    let cursor;
    do {
      const batch = await this.storage.list({ ...(cursor ? { startAfter: cursor } : {}), limit: 500 });
      for (const [key, item] of batch) {
        cursor = key;
        if (item.expiration !== null && item.expiration <= Date.now()) await this.storage.delete(key);
      }
      if (batch.size < 500) break;
    } while (true);
    await this.storage.setAlarm(Date.now() + 3600_000);
  }
}
