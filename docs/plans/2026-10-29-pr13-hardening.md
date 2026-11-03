# PR 13 cloud call hardening

## Spec and global constraints

User authorized fixing the reviewed ownership/401 issues, regression testing, and squash merging PR 13 into VoBLE. No release, installation or production deployment. Preserve the other worktree's uncommitted feedback/VoWLAN changes. Existing PR base is 5bd9d9b; reviewed head c81b804. Use the native isolated worktree. No force push.

The original PR's bounded event FIFO, terminal-event cleanup and per-call media ownership remain. Outgoing ownership must not be learned from an arbitrary queued outgoing event: capture pre-dial Telecom IDs and select only a unique new outgoing call matching the dialed number. Move session creation inside the uncached successful dial path so replaying cached commands does not recreate sessions. Media 401 gets a per-session monotonic 60-second recovery window, reset only after successful handshake; 410 and other permanent rejections still stop. No new VoIP push or descriptor on a media retry.

### Task 1: Outgoing ownership

Files: StandaloneAgentGateway, StandaloneAgentService, StandaloneCloudMediaManager; new manager integration tests and runner.

Interfaces: gateway captures pre-dial IDs; manager accepts call descriptor, pre-dial IDs and dialed number; the event handler binds only the unique live new Telecom call. Existing incoming IDs stay fixed.

1. Add real-manager regression tests using fake external Relay/socket boundaries: late ended/active from old outgoing, unrelated incoming/call waiting, legitimate new outgoing binding, owned terminal cleanup and dropped terminal isolation.
2. Run tests. Expected: old outgoing event is incorrectly accepted on PR head (RED).
3. Implement the ownership change and cover gateway cached dial behavior where practical.
4. Run focused tests and Android JVM suite. Expected: all pass. Commit.

### Task 2: Bounded media authentication recovery

Files: CloudCallRetryPolicy, StandaloneCloudMediaManager, policy and manager tests.

Interfaces: session-local policy takes monotonic time plus Telecom state; a successful handshake resets its unauthorized window. Event FIFO policy unchanged.

1. Add 401 initial/repeated/exhausted/recovery/reset tests; 410 stays immediate and sessions have independent windows.
2. Run tests. Expected: initial 401 stops too soon (RED).
3. Implement session-local retry window and hook success/reset into actual media loop.
4. Run focused and full Android tests. Expected: green. Commit.

### Task 3: Integration, documentation and merge

Files: standalone README and test harness only as needed to restore baseline lifecycle test compilation.

1. Run standalone full test script. Expected baseline: 11 missing Android test-stub APIs, not production errors. Repair only required test stubs, then rerun the entire script.
2. Document retry/ownership boundaries and real-device limitations. Run Relay tests as unchanged-protocol regression, diff checks and independent whole-branch review.
3. Resolve important review findings with RED/GREEN tests. Push only verified commits to the PR head if maintainer permissions allow; otherwise stop before merging an unfixed PR.
4. Recheck exact PR SHA/base, squash merge into VoBLE after tests pass, verify remote merge SHA. Do not pull/reset the dirty VoBLE worktree.

## Review focus

Final-review refinement: replace live-only pre-dial ID selection with a pre-dial creation observation. It retains removed calls until ownership binding so calls ending before event drain or session creation can release their own session. Capture only the first 15 seconds and at most 64 calls; ambiguous/overflow observations fail closed. Close observations on binding, failure, and session shutdown. The original task interfaces below are superseded by this refinement.

Late old outgoing events before/after new dial; events arriving before session creation; duplicate command replay; ambiguous same-number calls; stopped session slot retention; 401 mixed with timeouts/5xx, successful handshake reset, stale session cleanup; lock ordering and no real network in tests.
