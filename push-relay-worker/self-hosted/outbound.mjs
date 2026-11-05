// APNs requires HTTP/2, which is provided by the private Node bridge.
// Other outbound requests (e.g. manual Notion feedback) keep native fetch behavior.
export default {
  fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === 'https:' && ['api.push.apple.com', 'api.sandbox.push.apple.com'].includes(url.hostname)) {
      const headers = new Headers(request.headers);
      headers.set('x-airsim-apns-origin', url.origin);
      return env.APNS_HTTP.fetch(new Request(request, { headers }));
    }
    return env.INTERNET.fetch(request);
  },
};
