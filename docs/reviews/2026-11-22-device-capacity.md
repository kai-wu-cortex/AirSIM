# Device capacity and retention

The report describes a seventh device displacing the sixth in the app and Live Activity/widget. Current develop has no explicit six-device pairing limit. Confirmed issues are an eight-record VoWLAN persistence cap, a twelve-device widget snapshot cap, and omission of saved offline peers from the live device selector. The exact six-to-seven sequence has not been reproduced on hardware.

Changes:
- Persist all VoWLAN pairing records; serialize read/update/remove operations to prevent concurrent updates from losing a device.
- Scope record identity and replacement to the Agent, not just the secret fingerprint. Two distinct agents using the same credential no longer replace each other. Old record IDs load normally and are updated when that same agent is remembered, retaining its creation time and endpoint history. Keychain keys and carrier command authentication are unchanged.
- Retain saved offline devices in presentation with all transport availability flags false. Do not change route selection or mark them authenticated/online.
- Include all devices in the widget snapshot. Layout remains bounded to available screen space; switching devices uses the complete list.
- Send only the current three-row page to ActivityKit, preserving total count and current-device identity/SIM signals separately. Decode older full-list activity states as before. Device count is not limited by one activity payload.
- Page through all Cloudflare KV fallback roster results, rather than reading only the first 100.

Validation:
- Production Swift persistence/model smoke checks: 100 sequential pairings, reload, re-pair and removal, 32 concurrent additions, shared-credential identity isolation, legacy record update, offline roster retention, full 100-device paging, bounded activity payloads, legacy activity decoding, and 100-device widget roundtrip.
- SIM display smoke checks remain passing.
- Relay tests and two new KV pagination cases: 71 passed.
- iOS device build verified without signing, including app extensions and Watch.

No device installation, server deployment, release or carrier operation is included. Software pairing count is uncapped; simultaneous physical BLE connections remain subject to platform/radio capacity. Already discarded records cannot be reconstructed from the truncated store alone.
