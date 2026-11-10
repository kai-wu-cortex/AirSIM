# Watch direct call v2 — PR #36 integration contract

Status: source implementation and automated validation complete; device acceptance pending. No deployment or release implied.

Only private-network HTTP VoWLAN is supported here. Existing iPhone, cloud, BLE,
TLS and receive-only early media protocols are unchanged. Unsupported gateways
must return 404; Watch falls back to its existing iPhone companion path *before*
a direct answer is attempted. A failed/uncertain direct answer must never cause
a second answer through another transport.

## Credentials and control

- `Kwatch = HMAC-SHA256(Kpair, UTF8("AirSIM/watch-call-only/v2"))`.
- Kwatch is transferred only through paired WatchConnectivity and stored in the
  Watch Keychain. It is never accepted by the ordinary PCM or general API.
- `POST /api/watch/status`, `/api/watch/answer`, `/api/watch/hangup` only.
- Existing VoWLAN HMAC canonical request, version 1, timestamp ±30 seconds,
  unique nonce; header `X-AirSIM-Watch-Control: 2` is mandatory.
- Body: `agent_id`, `call_id`, `call_uuid` (lowercase UUID), `generation` (>0).
  Match **all fields** against a fresh backend identity, not client claims and
  not the latest global generation. Use `/api/calls/resolve` or equivalent
  exact tuple lookup. Restrict this feature to incoming calls.
- Resolve immutable native call instance once. Retain bounded tuple tombstones
  to answer terminal status without matching a new call. Unknown is not ended.
- Answer is idempotent for one parent pairing owner + exact tuple. Reserve the
  owner before issuing the native action. Only a ringing call can acquire a new
  claim. Already active on another device must not be seized.
- Response envelope: `{"payload":"<base64url UTF8 JSON>","proof":"..."}`.
  Proof: HMAC(Kwatch, `watch-response-v2\n<request_nonce>\n<HTTP_status>\n<payload>`).
  Payload includes `version:2`, echoed identity tuple, `state`, optional `grant`.
  Watch verifies proof, exact tuple and explicit version before acting.

## Duplex media grant

Only after backend/native state is active (not merely an answer ACK), response
may include `grant`, a base64url UTF8 JSON string whose fields are:
`owner` (parent pairing fingerprint), `agent_id`, `call_id`, `call_uuid`,
`generation` (backend generation), `instance` (immutable native instance),
`session` (random UUID), `expires_at` (Unix seconds, creation +60),
`session_until` (Unix seconds, creation +14400).

The exact encoded grant string is authenticated; no JSON reserialization for
MACs. `Kmedia = HMAC-SHA256(Kwatch, "watch-media-v2\n" + grant)`.
The media key is never sent in HTTP. Only one live grant/owner may exist for a
native instance. Answer retries reuse the same grant, never mint an unlimited
new TTL. Parent unpairing invalidates control and active media.

PCM preface (ASCII LF terminated):
`AIRSIMWATCH2 <grant> <timestamp> <nonce> <signature>\n`
Signature is HMAC(Kmedia,
`watch-pcm-v2\n<grant>\n<timestamp>\n<nonce>`), base64url without padding.
Existing `AIRSIMVWL1` must NOT accept Kwatch or Kmedia.

At attach: verify issued grant, parent still paired, complete tuple and native
instance still active, TTL, timestamp, replay protection, and global PCM mutex.
Check again before READY. During stream, revalidate exact instance/tuple and
pairing at most every 250ms; close on terminal, identity change, unpair, hard
session limit or transport failure. Never redirect the stream to a new call.
Attach expiry does not end an already attached valid call; session_until does.
A retry before expires_at may reconnect only after prior PCM ownership releases.

## Acceptance

Missing capability and old versions retain companion fallback. Verify rejected
old credentials, wrong parent/call/UUID/generation, tampered/expired grant,
replayed preface, duplicate PCM, ended call, unpair and next call. Validate
locked iPhone + Watch answer, iPhone answers first, late/duplicate terminal
updates, and normal iPhone/cloud/BLE/early media regression independently.
No real calls are authorized by this document.

## Compatibility boundaries and vectors

Optional health field: `watch_direct_version: 2`. A signed status payload with
`version: 2` is the authoritative negotiation. States: `incoming`, `connecting`,
`active`, `held`, `ended`, `unknown`. generation is a positive JSON integer;
owner is the lowercase SHA256(Kpair) hex fingerprint. Test vectors are in
`watch-direct-v2-vectors.json` (fixture keys only).

Both Standalone and U30Air currently resolve the full identity from their
incoming push descriptor. If a purely local call has no authenticated push
tuple, v2 does not guess UUID/generation: it rejects the direct request and
Watch uses the existing companion path before any direct answer. Cloud push
identity does not imply cloud media; supported v2 audio stays on private TCP.
A future native local identity discovery protocol is a separate change.

U30Air parent revocation is a device-loopback administration operation; the
client unpair UI does not yet invoke it. Device pair deletion/reset must close
issued grants; this is distinct from removing a device only on iPhone.
Existing grants cannot be resurrected by readding a revoked parent. A long
call whose media disconnects after its 60-second attach window requires an
explicit new handoff; this release does not silently renew grants.
