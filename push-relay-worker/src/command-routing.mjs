const encoder = new TextEncoder();
export class RoutingError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export function parseAgentID(value, { optional = false } = {}) {
  if (value == null && optional) return null;
  if (typeof value !== "string" || !value || value !== value.trim()
      || /[\x00-\x1f\x7f]/u.test(value) || encoder.encode(value).length > 128
      || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value)) {
    throw new RoutingError(400,"invalid_agent_id");
  }
  return value;
}
export function agentSocketKey(agentID) { return agentID == null ? "agent:legacy" : `agent:id:${agentID}`; }
export function matchesTarget(recordAgentID, callerAgentID) { return (recordAgentID ?? null) === (callerAgentID ?? null); }
export function resolveTarget(requested, activeAgentIDs) {
  if (requested !== undefined) return parseAgentID(requested, {optional:true});
  const candidates = [...new Set(activeAgentIDs)];
  if (candidates.length > 1) throw new RoutingError(409,"target_agent_required");
  if (candidates.length === 0) return null; // Historical pending commands remain legacy.
  return candidates[0];
}
export function requestAgentID(request) {
  const raw = request.headers.get("x-airsim-agent-id");
  try { return parseAgentID(raw === null ? null : decodeURIComponent(raw), {optional:true}); }
  catch { throw new RoutingError(400,"invalid_agent_id"); }
}
