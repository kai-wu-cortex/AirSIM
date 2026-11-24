# IMS caller number presentation

Scope: Android call event/CallRepository output and iOS CallRecord decoding, CallKit (shared with Watch), and contact display/matching. MU300 work is coordinated with chat 01a196b4-3b9f-76d1-a008-aafb2ba9f164; this change does not edit its repository or device.

## Rules

- Project only numeric SIP/SIPS/TEL callers, plus legacy scheme-less numeric@host.
- Decode the subscriber once, preserve + and 00, remove visual separators, never derive a country code from IMS domains.
- Accept user=phone and SIP transport=udp/tcp/tls; reject duplicate/unknown parameters and retain ambiguous phone-context/ext/isub addresses verbatim.
- Retain anonymous, alphabetic users, malformed escapes/hosts, controls and overlong values. Contact matching does not extract digits from opaque URI domains.
- Keep call IDs, Android IDs, source device/call IDs, SIM positions, states and timestamps unchanged. Do not alter dial/SMS request normalization or SIM/account identifiers.
- Android uses complete Uri.toString(), avoiding loss of scheme and percent-decoding twice. Common InCallService emission supplies local/VoBLE/cloud paths.

## Verification

- Shared 33-case Swift/Java fixtures passed, including idempotence and invalid inputs.
- Production CallRecord decode/encode check preserves IDs, SIM position/state and cleans display number.
- Android call repository test verifies SIP-to-tel display changes preserve logical call ID; cloud call suites passed.
- Android phone-control-app/test.sh passed, including SMS compatibility/receipts and E2E regression.
- Android Standalone Debug APK build and API 29 compatibility check passed. URLDecoder uses the older charset-name overload.
- iOS/Watch/extensions Debug device-target build succeeded.
- iOS SMS identity 62 checks and PushKit phone/Watch 26 checks passed.
- Added native CallKit XCTest for raw caller-name fallback; full native XCTest suite was not run.
- android-standalone/test.sh remains blocked by its existing candidate version assertion (Manifest mismatch); do not count that wrapper as passing.

Not installed/published; no real calls or SMS initiated. MU300 implementation completion must be confirmed separately by its responsible chat.
