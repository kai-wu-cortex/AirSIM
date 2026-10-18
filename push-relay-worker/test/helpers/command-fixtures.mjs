import { DeviceCommandSession } from "../../src/index.mjs";

class Storage {
  values = new Map();
  alarmAt = null;
  async get(key) { return structuredClone(this.values.get(key)); }
  async put(key, value) { this.values.set(key, structuredClone(value)); }
  async delete(key) { return this.values.delete(key); }
  async list({ prefix = "" } = {}) {
    return new Map([...this.values].filter(([k]) => k.startsWith(prefix)).map(([k,v]) => [k,structuredClone(v)]));
  }
  async setAlarm(at) { this.alarmAt = at; }
  async getAlarm() { return this.alarmAt; }
  async deleteAlarm() { this.alarmAt = null; }
}
class Socket {
  readyState = 1;
  closed = false;
  sent = [];
  serializeAttachment(value) { this.attachment = structuredClone(value); }
  deserializeAttachment() { return structuredClone(this.attachment); }
  close(code, reason) { this.closed = true; this.readyState = 2; this.code = code; this.reason = reason; }
  send(value) { if (this.readyState !== 1) throw new Error("closed"); this.sent.push(JSON.parse(value)); }
}
export function makeCommandHarness() {
  const storage = new Storage();
  const state = {
    storage, sockets: [],
    getWebSockets(tag) { return this.sockets.filter(s => s.readyState !== 3 && (!tag || s.tags.includes(tag))); },
    acceptWebSocket(socket, tags) { socket.tags = tags; this.sockets.push(socket); },
  };
  const session = new DeviceCommandSession(state);
  const headers = agentID => agentID === null ? {} : { "x-airsim-agent-id": encodeURIComponent(agentID) };
  return {
    state, storage, session,
    async connect(agentID) {
      const ResponseBefore = globalThis.Response, PairBefore = globalThis.WebSocketPair;
      globalThis.WebSocketPair = class { constructor() { this[0] = new Socket(); this[1] = new Socket(); } };
      globalThis.Response = class extends ResponseBefore {
        constructor(body, init) { if (init?.status === 101) return {status:101,webSocket:init.webSocket}; super(body,init); }
      };
      try {
        const response = await session.fetch(new Request("https://internal/connect", {headers:{upgrade:"websocket",...headers(agentID)}}));
        return { response, socket: state.sockets.at(-1) };
      } finally { globalThis.Response = ResponseBefore; globalThis.WebSocketPair = PairBefore; }
    },
    enqueue(command) { return session.fetch(new Request("https://internal/enqueue", {method:"POST",body:JSON.stringify(command)})); },
    async pull(agentID) { return (await session.fetch(new Request("https://internal/pending", {method:"POST",headers:headers(agentID)}))).json(); },
    complete(agentID,value) { return session.fetch(new Request("https://internal/complete", {method:"POST",headers:headers(agentID),body:JSON.stringify(value)})); },
  };
}
