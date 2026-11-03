package com.airsim.phonecontrol;

import android.telecom.Call;

public final class CallRepositoryTests {
    public static void main(String[] args) {
        watchdogRequiresPCMAndConfirmedControlIdentity();
        oldHangupCompletionCannotCloseReplacementLease();
        newDialOwnershipIgnoresIncomingAndDifferentOutgoingCalls();
        lateDialCompletionAfterProxyLossEndsOnlyThatCall();
        lossOfOldDirectSessionCannotEndAnotherCall();
        answerNeverTargetsAnActiveCallWithoutRinging();
        cloudRejectTargetsOnlyItsAuthenticatedCall();
        cloudCallEventsDriveOnlyTheirOwnCall();
        localRejectUsesPublishedCallIdentity();
        System.out.println("call repository tests passed");
    }

    private static void watchdogRequiresPCMAndConfirmedControlIdentity() {
        DirectCallOwnership.Lease lease = DirectCallOwnership.begin("127.0.0.1");
        Call target = new Call(Call.STATE_ACTIVE);
        String id = CallRepository.add(target);
        try {
            if (RemoteCallAudioScope.SHARED.owns(java.util.List.of(id))) throw new AssertionError("PCM alone owns no call");
            DirectCallOwnership.record("127.0.0.1", id, lease);
            if (RemoteCallAudioScope.SHARED.owns(java.util.List.of(id))) throw new AssertionError("control without ready PCM owns no audio");
            DirectCallOwnership.pcmReady(lease);
            if (!RemoteCallAudioScope.SHARED.owns(java.util.List.of(id))) throw new AssertionError("confirmed control + ready PCM must own audio");
            DirectCallOwnership.end(lease, false);
            if (RemoteCallAudioScope.SHARED.owns(java.util.List.of(id))) throw new AssertionError("closed lease still owns audio");
        } finally { DirectCallOwnership.end(lease, false); CallRepository.remove(target); }
    }

    private static void oldHangupCompletionCannotCloseReplacementLease() {
        DirectCallOwnership.Lease old = DirectCallOwnership.begin("127.0.0.1");
        DirectCallOwnership.end(old, true);
        Call replacement = new Call(Call.STATE_ACTIVE);
        String id = CallRepository.add(replacement);
        DirectCallOwnership.Lease current = DirectCallOwnership.begin("127.0.0.1");
        try {
            DirectCallOwnership.record("127.0.0.1", id, current);
            DirectCallOwnership.end(old, false);
            DirectCallOwnership.end(current, true);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(replacement.getState()));
        } finally { CallRepository.remove(replacement); }
    }

    private static void newDialOwnershipIgnoresIncomingAndDifferentOutgoingCalls() {
        java.util.Set<String> before = CallRepository.callIDs();
        Call incoming = new Call(Call.STATE_RINGING, Call.Details.DIRECTION_INCOMING, "2025550100");
        Call otherOutgoing = new Call(Call.STATE_ACTIVE, Call.Details.DIRECTION_OUTGOING, "2025550101");
        Call target = new Call(Call.STATE_ACTIVE, Call.Details.DIRECTION_OUTGOING, "2025550199");
        CallRepository.add(incoming);
        CallRepository.add(otherOutgoing);
        try {
            assertEquals("", CallRepository.newOutgoingCallSince(before, "2025550199"));
            String id = CallRepository.add(target);
            assertEquals(id, CallRepository.newOutgoingCallSince(before, "2025550199"));
        } finally { CallRepository.remove(incoming); CallRepository.remove(otherOutgoing); CallRepository.remove(target); }
    }

    private static void lateDialCompletionAfterProxyLossEndsOnlyThatCall() {
        DirectCallOwnership.Lease lease = DirectCallOwnership.begin("127.0.0.1");
        DirectCallOwnership.Lease captured = DirectCallOwnership.capture("127.0.0.1");
        DirectCallOwnership.end(lease, true);
        Call created = new Call(Call.STATE_ACTIVE);
        Call other = new Call(Call.STATE_RINGING);
        String id = CallRepository.add(created);
        CallRepository.add(other);
        try {
            DirectCallOwnership.record("127.0.0.1", id, captured);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(created.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
        } finally { CallRepository.remove(created); CallRepository.remove(other); }
    }

    private static void lossOfOldDirectSessionCannotEndAnotherCall() {
        Call target = new Call(Call.STATE_ACTIVE);
        Call other = new Call(Call.STATE_RINGING);
        String targetID = CallRepository.add(target);
        String otherID = CallRepository.add(other);
        try {
            DirectCallOwnership.Lease lease = DirectCallOwnership.begin("127.0.0.1");
            DirectCallOwnership.record("127.0.0.1", targetID);
            // A later call/control completion must not be attached to an old PCM lease.
            DirectCallOwnership.record("127.0.0.1", otherID);
            DirectCallOwnership.end(lease, true);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            DirectCallOwnership.end(lease, false);
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void answerNeverTargetsAnActiveCallWithoutRinging() {
        Call active = new Call(Call.STATE_ACTIVE);
        Call ringing = new Call(Call.STATE_RINGING);
        String activeID = CallRepository.add(active);
        String ringingID = CallRepository.add(ringing);
        try {
            assertEquals(ringingID, CallRepository.idForAction("answer"));
            CallRepository.remove(ringing);
            assertEquals("", CallRepository.idForAction("answer"));
            assertEquals(activeID, CallRepository.idForAction("end"));
        } finally {
            CallRepository.remove(ringing);
            CallRepository.remove(active);
        }
    }

    private static void cloudCallEventsDriveOnlyTheirOwnCall() {
        String owned = "0c8f8a52-3f7e-4f0e-9d2b-6a1e5f4c3b2a";
        String waiting = "a41d2c9e-77b0-4e61-8f3a-2c5d9e8b7f10";
        assertTrue(CloudCallTarget.owns(owned, owned));
        // Call waiting: the second call's ringing or ended must not drive or end the cloud call.
        assertTrue(!CloudCallTarget.owns(owned, waiting));
        // An outgoing cloud call learns its Telecom id from its first outgoing event; until then an
        // earlier call's late event does not belong to it.
        assertTrue(!CloudCallTarget.owns("", waiting));
        assertTrue(!CloudCallTarget.owns("", ""));
        assertTrue(!CloudCallTarget.owns(owned, ""));
    }

    private static void cloudRejectTargetsOnlyItsAuthenticatedCall() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            CloudCallTarget identity = new CloudCallTarget(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3, targetID);
            String selected = identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3);
            assertEquals(targetID, selected);
            CallRepository.ActionResult result = CallRepository.execute(
                    null, new AgentCommand("command-7", "reject", selected, ""));
            assertTrue(result.success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", identity.resolve(
                    "relay-call-previous", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 3));
            assertEquals("", identity.resolve(
                    "relay-call-7", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", 2));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void localRejectUsesPublishedCallIdentity() {
        Call other = new Call(Call.STATE_RINGING);
        Call target = new Call(Call.STATE_RINGING);
        String otherID = CallRepository.add(other);
        String targetID = CallRepository.add(target);
        try {
            String selected = CallRepository.idForPublishedAction(
                    "reject", "visible-target", "visible-target", targetID);
            assertEquals(targetID, selected);
            assertTrue(CallRepository.execute(
                    null, new AgentCommand("local-reject", "reject", selected, "")).success);
            assertEquals(Integer.toString(Call.STATE_DISCONNECTED), Integer.toString(target.getState()));
            assertEquals(Integer.toString(Call.STATE_RINGING), Integer.toString(other.getState()));
            assertEquals("", CallRepository.idForPublishedAction(
                    "reject", "stale-visible-call", "visible-target", targetID));
            assertEquals("", CallRepository.idForPublishedAction(
                    "answer", "visible-target", "visible-target", targetID));
        } finally {
            CallRepository.remove(target);
            CallRepository.remove(other);
        }
    }

    private static void assertTrue(boolean value) {
        if (!value) throw new AssertionError("expected true");
    }

    private static void assertEquals(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
        }
    }
}
