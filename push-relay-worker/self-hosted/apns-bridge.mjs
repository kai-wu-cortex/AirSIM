import http from 'node:http';
import http2 from 'node:http2';
import { pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';

const origins = new Set(['https://api.push.apple.com', 'https://api.sandbox.push.apple.com']);
export function createAPNsBridge({ connect = http2.connect } = {}) {
  const sessions = new Map();
  const server = http.createServer(async (req, res) => {
    const origin = req.headers['x-airsim-apns-origin'];
    if (!origins.has(origin) || req.method !== 'POST' || !/^\/3\/device\/[0-9a-f]{16,512}$/i.test(req.url)) {
      res.writeHead(400).end('invalid APNs request'); return;
    }
    let size = 0;
    const chunks = [];
    try {
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 4096) { res.writeHead(413).end(); return; }
        chunks.push(chunk);
      }
      let session = sessions.get(origin);
      if (!session || session.closed || session.destroyed) {
        session = connect(origin);
        sessions.set(origin, session);
        session.on('error', () => { session.destroy(); });
        session.on('goaway', () => { if (sessions.get(origin) === session) sessions.delete(origin); session.close(); });
        session.on('close', () => { if (sessions.get(origin) === session) sessions.delete(origin); });
      }
      const headers = { ':method': 'POST', ':path': req.url };
      for (const [key, value] of Object.entries(req.headers)) {
        if (key === 'authorization' || key === 'content-type' || key.startsWith('apns-')) headers[key] = value;
      }
      const stream = session.request(headers);
      stream.setTimeout(15000, () => stream.destroy(new Error('APNs timeout')));
      res.on('close', () => { if (!stream.closed) stream.close(); });
      stream.on('response', h => {
        const responseHeaders = {};
        for (const key of ['apns-id', 'content-type', 'retry-after']) if (h[key]) responseHeaders[key] = h[key];
        res.writeHead(Number(h[':status']), responseHeaders);
      });
      stream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('APNs transport unavailable'); });
      stream.pipe(res);
      // Never automatically replay a push after an ambiguous transport failure.
      stream.end(Buffer.concat(chunks));
    } catch {
      if (!res.headersSent) res.writeHead(502);
      res.end('APNs transport unavailable');
    }
  });
  server.requestTimeout = 20000;
  server.headersTimeout = 10000;
  return { server, close() { for (const s of sessions.values()) s.destroy(); server.closeAllConnections(); return new Promise(r => server.close(r)); } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const bridge = createAPNsBridge();
  bridge.server.listen(Number(process.env.APNS_BRIDGE_PORT || 8790), '127.0.0.1', () => console.log('APNs HTTP/2 bridge listening on loopback'));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => bridge.close().then(() => process.exit(0)));
}
