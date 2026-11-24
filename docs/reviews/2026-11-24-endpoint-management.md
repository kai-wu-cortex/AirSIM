# Endpoint management

The Address and Pairing Information page now offers a per-endpoint delete button and confirmation, disabled during calls. Deletion retains the device record, Keychain credentials, other endpoints, SMS and call history. Removing the final endpoint leaves the pairing intact.

Deletion clears matching manual routes, live directory peers and AppModel offline/control API caches. It invalidates in-flight probes/configuration generations and persists a device-scoped endpoint exclusion so later Bonjour/verification results cannot restore the address. Explicit manual configuration or pairing can re-enable it. No device-side configuration is modified.

After successful signed identity verification, a new control/PCM port pair replaces prior entries for that device, normalized host and transport. Other devices, other hosts and plaintext/TLS remain separate. Merely saving an unverified public mapping does not remove trusted old addresses. Existing duplicate entries can be removed individually or consolidated when the desired endpoint verifies.

Verification:
- Production persistence test: scoped replacement, unverified preservation, late-result suppression, deletion/restart, last endpoint, explicit restore and TLS separation passed.
- Device capacity regression: 100 pairings, concurrent saves, paging and widget roundtrip passed.
- Eight production LAN-first route policy tests passed, including call-locked route preservation.
- iOS/Watch/widget Debug device build passed; git diff --check passed.

No real network switching/call was initiated. Not installed, committed or published in this task. Existing unrelated worktree changes are retained.
