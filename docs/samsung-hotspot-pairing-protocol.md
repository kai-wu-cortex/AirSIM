# Samsung hotspot one-time pairing

## Scope

This protocol transfers the existing iOS `AgentPushRegistration` to the Linux Agent running in Android 16 AVF. It is available only while the foreground Android activity has an explicit two-minute pairing session open.

## Discovery

- DNS-SD service: `_airsim-pair._tcp.local.`
- TXT `v`: `1`
- TXT `session`: random UUID
- TXT `key`: base64url-encoded 32-byte ephemeral X25519 public key
- TXT `expires`: Unix epoch milliseconds
- TXT `e2e`: `1`, only from the Standalone Agent, which keeps an end-to-end SMS key (issue #24); absent in AVF mode

The six-digit confirmation code is deliberately not advertised. It is displayed only by the Samsung activity and entered on the iOS device.

## Claim

iOS creates an ephemeral X25519 key pair and derives:

```text
shared = X25519(iOS_private, Samsung_public)
key = HKDF-SHA256(shared, salt=UTF8(session), info=UTF8("AirSIMPair/v1:" + code), length=32)
sealed_registration = nonce(12) || AES-256-GCM(registration_json, key, aad=UTF8(session))
```

It opens the advertised Bonjour endpoint and sends:

```http
POST /pair/v1/claim HTTP/1.1
Content-Type: application/json

{
  "version": 1,
  "session_id": "...",
  "client_public_key": "base64url...",
  "sealed_registration": "base64url..."
}
```

The Android bridge accepts private/link-local peers only, limits headers to 8 KiB and bodies to 32 KiB, and never persists the decrypted registration. It forwards the plaintext over the AVF-only authenticated control channel to `POST /api/android/pair/register`. The Agent validates and atomically persists it using the existing Push registration store.

### End-to-end SMS key (issue #24)

- iOS adds `e2e_key` to `registration_json` only for a cloud registration, and only when both the Agent (TXT `e2e=1` or `GET /pair/v1/info` `capabilities.e2e_sms: 1`) and the Relay (`/healthz` `capabilities.e2e_sms: 1`) advertise support. The value is 32 random bytes, base64url without padding; Android rejects any other encoding or length and the claim fails.
- Android removes `e2e_key` before `registerPairing` in every mode. Only the Standalone Agent keeps it, per iPhone `device_id` and Relay URL; it is never stored with the registration, logged or uploaded.
- Every cloud pairing replaces the key; a cloud claim without `e2e_key` removes the previous one. A local-mode pairing never keeps a key, so iOS must not keep one for it either.
- `e2e_key` travels only in this sealed claim, never in the HMAC-signed `POST /api/push/register` refresh, where Android drops it.

## Replay and diagnostics

- Session lifetime: 120 seconds.
- A session becomes unusable immediately after a correctly authenticated claim is decrypted.
- An incorrect code does not reveal which input failed and may be retried while the session remains open.
- Logs include session lifecycle, trace/result state and safe device-ID suffixes only. Private keys, codes, device secrets, and Push tokens must never be logged.
