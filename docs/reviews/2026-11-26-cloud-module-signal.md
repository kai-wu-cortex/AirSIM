# MU300 / U30 Air cloud signal display

## Cause

Modules report `signal_dbm`, without per-SIM `sim_slots[].signal`. iOS decoded
only the top-level cloud reading, not each Agent's radio. The Live Activity
also excluded local modem readings in cloud-only mode. Simply removing that
guard risks presenting another device's or an expired local reading.

## Change

- Record `signal_observed_at_ms` (Unix milliseconds) when AT+CSQ succeeds.
  Include it in scheduled and diagnostic heartbeats. Failed sampling does not
  renew it; CSQ 99 clears the sample. No additional AT queries were added.
- Relay validates the dBm and observation timestamp and preserves the original
  time. It never substitutes heartbeat time. These optional fields remain
  compatible with old heartbeats and clients. ECS and Cloudflare use this same
  source handler.
- iOS reads the selected Agent's radio from `agents[]`. A missing SIM roster
  permits a single cellular signal row; a present roster (including an empty
  one) remains authoritative. No global latest-Agent signal is borrowed.
- Reuse the existing 300-second signal lifetime and 60-second future clock
  tolerance. Offline, expired, invalid and un-timestamped signals are hidden.
  Phone number visibility remains independent.
- Widget and island share this display path. A cellular reading does not claim
  a physical SIM slot number. Android per-SIM telemetry remains unchanged.

## Validation

- `iOS/scripts/test-sim-display.sh` passed: cloud module decode, valid/zero/
  expired/future/offline/legacy readings, per-SIM precedence and explicit SIM
  removal, plus existing number privacy and expiration checks.
- Go targeted tests passed: CSQ observation/unknown handling and repeated
  heartbeats preserving the original timestamp. Log:
  `/tmp/airsim-cloud-signal-agent-tests.log`.
- All 87 Relay tests passed, including authorization, per-Agent isolation,
  missing/invalid timestamps and heartbeat replacement. Log:
  `/tmp/airsim-cloud-signal-relay-full-tests.log`.
- Signed iPhone build passed: `/tmp/airsim-cloud-signal-build.log`.

## Rollout boundary

Not deployed or installed in this turn. Deploy Relay first, update the module
Agent, then install the iPhone app. An iPhone-only update cannot supply the
observation time missing from an old Agent. Live cloud signal behavior still
requires device verification.

Attempted a synchronization message to the U30 maintenance chat
`01a196b4-3b9f-76d1-a008-aafb2ba9f164`; the tool did not acknowledge delivery.
Do not assume it was received. This document is the local handoff record.
