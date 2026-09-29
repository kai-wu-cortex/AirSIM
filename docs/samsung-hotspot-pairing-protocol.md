# Samsung hotspot one-time pairing

## Scope

This protocol transfers the existing iOS `AgentPushRegistration` to the Linux Agent running in Android 16 AVF. It is available only while the foreground Android activity has an explicit two-minute pairing session open.

## Discovery

- DNS-SD service: `_djonehub-pair._tcp.local.`
- TXT `v`: `1`
- TXT `session`: random UUID
- TXT `key`: base64url-encoded 32-byte ephemeral X25519 public key
- TXT `expires`: Unix epoch milliseconds

The six-digit confirmation code is deliberately not advertised. It is displayed only by the Samsung activity and entered on the iOS device.

## Claim

iOS creates an ephemeral X25519 key pair and derives:

```text
shared = X25519(iOS_private, Samsung_public)
key = HKDF-SHA256(shared, salt=UTF8(session), info=UTF8("DJOneHubPair/v1:" + code), length=32)
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

## Replay and diagnostics

- Session lifetime: 120 seconds.
- A session becomes unusable immediately after a correctly authenticated claim is decrypted.
- An incorrect code does not reveal which input failed and may be retried while the session remains open.
- Logs include session lifecycle, trace/result state and safe device-ID suffixes only. Private keys, codes, device secrets, and Push tokens must never be logged.
