# 2026-10-31 — Background CallKit repair

## Observed evidence

- Physical iPhone Air is running TestFlight 0.9.8 (149). Pure-local was off and
  cloud notifications were on, with VoWLAN selected.
- Upgrading changed the iPhone APNs tokens. The Relay initially still held a
  sandbox registration; manual diagnostics updated it to production.
- A reproduced incoming `/v2/events/call` request returned HTTP 409 at
  2026-10-31 00:26:52 Asia/Shanghai, before APNs delivery. The captured response
  did not contain the rejection body, so the exact live reason is not proven.
- An isolated regression test reproduced `identity_mismatch`: a prior active
  call in the device-wide lifecycle record blocked unrelated new call UUIDs.
- Read-only MU300 diagnostics showed old sandbox credentials and tokens that
  differed from the iPhone's new tokens, plus a recent Relay request timeout.
- iPhone logs also contain HTTP 404 on gateway push registration/mode routes.
  A successful Relay self-test is not proof that a gateway accepted new tokens.

## Changes

1. Worker lifecycle records are scoped by device, Agent and call UUID. A lost
   terminal event cannot block new UUIDs until the old five-hour TTL expires.
   Existing TTLs remain; no active call is forcibly ended. Legacy records are
   consulted only for the same UUID, preserving terminal replay protection.
   Existing media records prevent cross-device/Agent UUID takeover.
2. iOS refreshes the Relay independently of local route availability. It queues
   all currently authenticated gateways, with per-route success/backoff state.
   Token/environment changes invalidate every gateway's registration cache.
   Verified/recovered gateways trigger synchronization regardless of media mode.
3. Notification preference and the pure-local egress gate control synchronization
   and retry. A gateway's local-only pairing is preserved, not silently upgraded.
4. Opt-in Verbose records PushKit receipt, registration results and CallKit report
   outcomes in Release builds. Logs exclude tokens, payloads, numbers and raw
   HTTP error bodies. Nothing is uploaded automatically.
5. Android authenticated VoWLAN control allows POST `/api/push/mode`; previously
   the handler existed but the route allowlist returned 404. Existing pure-local
   checks in the handler remain enforced.

## Deployment and validation

- Worker unit suite: 67 passed.
- Local workerd routing integration: passed.
- Android `test.sh`: passed, including CoreTests and compatibility suites.
- iOS focused tests: 17 passed (registration ledger, directory recovery,
  pure-local mode and Relay egress). Do not infer device success from a simulator
  test or an APNs HTTP acceptance.
- Authorized Worker deployment:
  `365bc19a-eec2-458b-9eea-7162fc86fdd1` on `airsim-push.remotepilot.site`.
- Previous deployment (rollback target if required):
  `5340a97b-2fc4-4449-a943-df4799f49dfc`.
- Production `/healthz` returned `ok: true`. No secrets/bindings were changed.
- iPhone/Android have NOT been overwritten by this repair. TestFlight 149 does
  not contain the client changes. No new Release/TestFlight upload is implied.
- These repairs are recorded separately from PR #18; unrelated `release-assets/`
  was left alone.

## Real-device acceptance

1. Keep pure-local off; run cloud diagnostics once on the production-signed app.
2. Return to the Home Screen and lock (do not force-quit the app for this test).
3. Call Samsung and MU300 separately. Correlate each incoming request's HTTP
   status, APNs result and physical CallKit presentation. Never equate heartbeat
   or successful device registration with successful incoming-call delivery.
4. Repeat two consecutive calls, then switch originating devices. Check ringing,
   answer, audio and hangup without affecting another device's active call.
5. After installing the client repair, confirm both reachable gateways receive
   the current environment/token. Offline gateways need to reconnect; a deployed
   gateway that lacks the registration route needs its own compatible update.
6. Enable pure-local and confirm no Relay registration/retry is sent. Local-only
   gateway pairings must stay local. Re-disable and retest notification sync.

After deployment, incoming call and call-state requests returned HTTP 202 and
the iPhone production APNs channel was accepted. The user subsequently confirmed
that CallKit appeared, but with a large delay. This does not establish which
stage caused the delay or certify reliable background delivery. PR #18 addresses
post-answer PCM startup cancellation, not APNs/ringing latency.

## PR #18 integration — 2026-10-31

- Reviewed PR head `5c8e2c9` against `VoBLE`; retained its independent audio
  startup task and call/owner/route validation without restoring poll-generation
  coupling. The earlier delivery/registration repairs are commit `e29139a`.
- Fixed the review finding: an observer joining an explicitly cancelled startup
  now waits for owner-scoped cleanup, rechecks the slot and starts or joins the
  replacement instead of silently discarding its request. No overlapping startup
  is introduced; a cancelled observer cannot revive audio.
- Added three tests for serial handoff/coalescing, cancelled waiters and repeated
  cancellation. Original polling-cancellation and late-rollback tests still pass.
- Integrated iOS unit suite: 373 passed, 0 failures on iOS 27 Simulator. This is
  the `AirSIMTests` target, not physical-device or UI-test acceptance.
- Worker unit suite: 67 passed; Android `test.sh`: passed; diff checks passed.
- No new Worker deployment is required for PR #18. No phone installation,
  Release asset or TestFlight upload was performed as part of this integration.
- Next device check: background/locked incoming CallKit answer, immediately
  foreground/background the app, confirm continuous two-way audio, then rapidly
  hang up and accept the next call. Test Samsung and MU300 separately. Correlate
  ringing latency independently; APNs acceptance alone is not a delivery receipt.
