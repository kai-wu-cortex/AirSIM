# PR #29 review and Agent compatibility

2026-11-04. Reviewed original head `2627e9c76c25e09831e4bf482e392d9fed808306` against `main` (`71006f4`). Work performed in isolated `codex/pr29-review`; existing VoBLE UI/audio work was not included or reset.

## Accepted changes

- Preserve SMS receiving SIM metadata through Android storage, Relay and APNs; choose outgoing SMS SIM per device/conversation with opaque account handles.
- Preserve PushKit system UUID while adopting an authenticated LAN call. Duplicate answers do not execute a second Telecom answer; late/duplicate terminal events cannot close a replacement call.
- Recover saved LAN addresses on cold launch, retain a verified route while an alternative fails, and avoid waiting behind an obsolete probe.
- Limit push registration retries and suppress cancellation-as-disconnection errors.

## Review corrections

1. Held-call answer: the PR admitted ACTIVE/HOLDING for a repeated answer, but its completion loop accepted only ACTIVE. A new JVM regression failed on HOLDING after the timeout. Completion now accepts HOLDING without invoking answer again; both states preserve their route/state.
2. Resolve identity: the legacy manager defaults missing generation to 1. A new test of the actual gateway reproduced successful resolution with the field omitted. The new resolve endpoint now requires an explicit positive integer; missing/null/boolean/fractional/invalid/overflow/nonpositive values return 409. Existing cloud-command defaults are unchanged. Tests also reject wrong IDs/UUIDs/generations, replacement calls and absent active calls.
3. Forgetting a device clears the new SMS SIM cache and conversation preferences together with pairing removal.

## Wire contract and rollout

| Endpoint / flow | Change | Compatibility |
| --- | --- | --- |
| `POST /api/calls/resolve` | New authenticated LAN route; JSON `call_id`, `call_uuid`, `generation` | Required when pushed and local call IDs differ. 200 returns the existing CallStatus shape; 409 means identity mismatch/stale; 404 prompts gateway upgrade. |
| `POST /api/calls/answer` | Repeated answer of the exact active/held call succeeds without re-answering | Never use another ringing call or infer ownership by number/time. |
| `POST /api/calls/history/ack` | Added to Android LAN allowlist | Old gateway 404 is remembered for this iOS process; relaunch retries after gateway upgrade. |
| `POST /api/calls/hangup` | iOS captures exact local call ID before sending/retrying | A lost response is reconciled against authenticated status/history. Never retry an unscoped hangup on a replacement call. |
| `POST /api/calls/audio/record` | Optional 404 cached by iOS | No recording capability added to Android. |
| Relay `POST /v1/devices/commands`, `type=send_sms` | Optional `sim_account` passed through | Device validates the opaque account; omission preserves default SIM behavior. Old Worker ignores selection, so update Worker before advertising cloud SIM selection. |
| Relay `POST /v1/events/sms` | Optional `sim_slot` forwarded into SMS APNs payload/subtitle | `SIM 1`…`SIM 99` display labels accepted; missing remains unknown. Encrypted payload stays opaque. |

Example resolve body (identifiers illustrative):

```json
{"call_id":"pushed-call-id","call_uuid":"11111111-1111-4111-8111-111111111111","generation":"1"}
```

Use existing paired authentication and anti-replay protections; this endpoint grants no unauthenticated control. The identity triple must resolve to the current same-device real call. It does not answer, start PCM, change state to active, or start connected duration. Successful parsing alone is not proof of call ownership.

Deploy compatible Android Standalone / U30Air Agent first, Worker for cloud SMS metadata/selection second, then the new iOS client. The PR description's “no Relay update” applies only to the local call identity resolution; the SMS changes require a Worker update. Existing AVF/Go Agent implementations have no resolve handler in this PR: verify their pushed/local IDs and implement mapping before relying on a differing-ID handoff. Do not weaken client identity checks to accommodate an old gateway.

U30Air coordination was sent, under the user's explicit authorization, to chat `01a196b4-3b9f-76d1-a008-aafb2ba9f164` (“修复插件通话无声音”). That chat owns U30Air source adaptation, tests and later device acceptance. No U30Air files/devices were modified by this review.

## Validation

- Original PR iOS build and all 476 unit tests passed: `/tmp/airsim-pr29-tests.xcresult`.
- Worker: 78/78 passed, `/tmp/airsim-pr29-worker.log`.
- Android main test script passed before and after held-call fix, including PCM/privileged SMS suites: `/tmp/airsim-pr29-android-fixed.log`.
- Actual Gateway/CloudCallManager and outgoing observation regression tests passed after strict resolve validation: `/tmp/airsim-pr29-resolve-fixed.log`.
- Android Standalone Debug build/signature verification passed; this review did not install it or use it as a Release artifact.
- Final iOS affected suites: 106/106 passed, `/tmp/airsim-pr29-fixed-tests.xcresult`. Final Android Standalone rebuild/signature verification passed: `/tmp/airsim-pr29-apk-final.log`.
- `git diff --check` passed.

## Remaining device acceptance

No real phone calls, SMS, audio recording, Worker deployment, installation, Release or TestFlight publication were performed. Validate locked-screen push → LAN answer, both audio directions, duplicate answer, held call, call waiting, same-number new call after old terminal, VPN/Wi-Fi changes, cold launch and dual-SIM SMS on the coordinated versions. Passing synthetic tests is not a claim of real-device repair.
