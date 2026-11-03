# VoWLAN background recovery investigation — 2026-10-31

## Report and scope

The user reports reproducible incoming calls stuck on “module connecting” after
closing/backgrounding the app, and much slower VoWLAN recovery, including in
pure-local mode. Whether “closing” means force-quitting or returning to the home
screen/locking, and the failing gateway/network, still need confirmation.

Read-only inspection of the connected iPhone Air found version 0.9.8 build 149.
That installed build predates PR #18 and the subsequent delivery/registration
repairs. The readable persisted trace spans 2026-10-31 00:21–00:42 Asia/Shanghai;
it is not confirmed to cover the overnight failure. Long-poll response durations
alone are not evidence of a slow health handshake.

## Confirmed code issues and local changes

1. `callInProgress` previously included an unconnected PushKit ringing state.
   Recovery/fallback gates therefore refused to repair the direct route needed
   to answer. An unanswered, unlocked call now permits discovery and signed
   authentication. Active calls and locked routes remain protected.
2. Cancelling a Swift HTTP task did not cancel its NWConnection. Foreground
   restart could leave old requests waiting until the original timeout, also
   delaying the audio coordinator's serial cancellation handoff. Cancellation
   now closes the operation on its serial queue, with a lock-protected holder
   covering cancellation before/during installation and one-shot completion.
   Cancelled requests cannot fall through to an interface retry. This targeted
   fix was adapted from the separate main worktree's existing transport changes;
   that worktree and its unrelated changes were not modified or merged.
3. Device discovery verified candidates sequentially. One offline paired gateway
   could delay an online peer. Independent peers now authenticate concurrently;
   per-device nonce/HMAC identity proof and forgotten-device guards remain.
4. Foreground polling retained the pre-suspension event cursor. Directory polling
   could also remain in an old request/backoff. Foreground refresh cancels those
   observers and uses `AgentEventCursor.initial` for an immediate authenticated
   snapshot. New directory peers also start with that sentinel, not revision 0,
   which can wait for the server's long-poll timeout when its revision is 0.

No Relay bypass, cloud fallback, permission bypass, automatic feedback upload,
or real phone call was introduced. No server deployment was performed. A later
authorized local installation is recorded below; these changes do not establish
that the device failure is fixed.

## Regression coverage / pending device acceptance

Added tests for unanswered-call route recovery versus active-call protection,
prompt HTTP cancellation and already-cancelled requests, independent gateway
authentication while another probe is stalled, and foreground snapshot cursors.
Validation on iOS 27 Simulator:

- First full run: 378 tests, one timeout in the existing two-device production
  chain test (`B terminal`); simulator logs also reported overload. This alone
  does not prove that the timeout was environmental.
- The unchanged failing test then passed three consecutive isolated runs.
- A second full `AirSIMTests` run passed all 378 tests, including pure-local /
  Relay egress and PR #18 cancellation/handoff tests (`TEST EXECUTE SUCCEEDED`).
- All five added regression tests passed. `git diff --check` passed.
- Local logs: `/tmp/airsim-background-recovery-tests.log`,
  `/tmp/airsim-background-recovery-isolated.log`, and
  `/tmp/airsim-background-recovery-confirm.log`. Changes remain uncommitted;
  do not describe them as shipped in build 149.

Device acceptance requires a new build (149 does not include these changes):

1. Same Wi-Fi: background and lock, dial the gateway SIM, answer through CallKit,
   verify two-way audio, hang up, repeat without reopening the app.
2. Reopen after a long idle: capture health verification, status snapshot and PCM
   startup separately; do not count an idle event long poll as handshake time.
3. Repeat with pure-local enabled, recognizing that it intentionally disables
   Relay/APNs signaling; test local reconnect separately from background wake.
4. Repeat with one paired gateway offline and the other online, then Tailscale.
5. Check real hangup/route replacement cannot revive old audio or target another
   phone. Preserve pairings and data; do not uninstall to obtain a clean test.

## Authorized local installation: 0.9.8 (150)

The user confirmed build 149 and requested an in-place local test installation
with data retained. Built the current `VoBLE` worktree with its uncommitted
recovery fixes, the existing local `Install.xcconfig`, and command-line build
number 150 (repository release metadata was not bumped).

- Physical iPhone Air installation and launch succeeded; device app inventory
  confirmed `com.eric3u.airsim`, version 0.9.8, build 150.
- Deep strict code-sign verification passed; original developer team retained.
- Signed APNs entitlement is `development` and app environment is `sandbox`.
  This is intentionally a local development build, not a production TestFlight
  upload. Alert/VoIP tokens changed following re-registration.
- No uninstall was performed. Before/after copies in the restricted local
  directory `/tmp/airsim-local150.HrMOmv` confirmed unchanged contacts/SMS,
  all 86 call-history records semantically unchanged, and both paired device
  identities retained in both device and VoWLAN pairing records. Keychain
  secrets were not exported or printed.
- Build log: `/tmp/airsim-local150.HrMOmv/build.log` (`BUILD SUCCEEDED`).
- User device acceptance remains pending: compare foreground recovery in
  pure-local mode, background/locked incoming calls after sandbox registration,
  and a separate force-quit case. Do not equate installation, automatic tests,
  or APNs registration with successful ringing/answer/two-way audio.
