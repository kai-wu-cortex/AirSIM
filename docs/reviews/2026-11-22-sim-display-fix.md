# SIM number and signal display correction

## Scope

Fix the existing shared SIM display pipeline. Preserve the pending PR #47 UI rollback; do not import PR #47, change call routing, send commands, or deploy services.

## Findings and changes

- SIM signal summaries omitted the phone number. The Live Activity chose signal rows instead of the existing number row, and widget device snapshots did not carry a device number.
- Carry each SIM number with its own slot/signal summary. Expanded Live Activity and home-screen widgets display these together. Compact indicators retain slot labels. Numbers remain when signal readings expire; privacy-sensitive rendering is retained.
- Preserve a bounded device-level number as a fallback when an older agent supplies no per-SIM numbers. Optional fields decode older snapshots without migration.
- Android previously polled subscription-scoped cached aggregate signal values. Add service-owned, per-subscription signal listeners, retain the newest valid sample, unregister removed subscriptions, and ignore late callbacks. Existing metadata publication serves VoWLAN, VoBLE and Relay.
- When Android exposes exactly one valid radio component, use its level rather than a conflicting aggregate. With multiple components, retain the platform aggregate; do not select the strongest component or copy the other SIM's signal.
- Unknown, stale, denied and unresolved measurements remain unknown, distinct from a valid zero-bar reading.

## Validation

- `sh iOS/scripts/test-sim-display.sh`: passed; production model roundtrip, reversed dual-SIM order, number/signal association, old snapshots, empty roster, blank number and expiration.
- `sh android/phone-control-app/test-sim-signals.sh`: passed; API-level branches, two subscriptions, component/aggregate behavior, newer callback, listener lifecycle, SIM removal and late callback, invalid/expired/denied data.
- iOS Debug device build including extensions/Watch: succeeded, signing disabled for verification.
- Android Standalone Debug build: succeeded.
- `git diff --check`: passed.
- Additional XCTest regression added to `SIMSignalDisplayTests`; full XCTest suite not run in this verification.

## Remaining verification

No device installation or carrier operation was performed. The phone-number omission is directly established in code. Per-model SIM1 signal correctness still requires a real dual-SIM device comparison (including non-default SIM, network change, and SIM removal). No claim that every OEM supplies accurate telemetry. Deploy both iOS and Android changes to test the full fix; Relay wire format is unchanged.

## Follow-up: retain every known SIM number when signal is unknown

- Expanded island / lock-screen device rows and widgets show slot, number and signal together for all reported SIMs; removed the four-row data/display truncation. Unknown slot indices are labeled unknown rather than inferred from ordering.
- Every visible device receives its own SIM rows, including non-selected devices. Compact island remains a short slot/signal indicator; expanded rows contain the numbers.
- Offline transport responses reuse that device's display-only snapshot with signal removed. Explicit empty SIM rosters still clear old cards. No cached display value authorizes dialing or SMS.
- Number changes trigger widget updates independently of signal changes. Signal expiration clears signal only, including the compact island's separate current-device data.
- Compact snapshot encoding preserves old JSON decoding while avoiding duplicated current-device rows. The 100-device paging test with eight 32-character numbers per visible device and current device off-page encodes to about 3.4 KB, below the test's 4 KB budget.
- SIM display / device capacity scripts pass, including unknown signals, stale activities, offline retention, explicit removal, eight SIM rows, legacy payloads and exact number/slot association. Build verification and actual flight-mode testing are tracked separately; no release or installation performed by this edit.
