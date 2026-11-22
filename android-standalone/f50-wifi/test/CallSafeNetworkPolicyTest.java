package com.airsim.f50wifi;

public final class CallSafeNetworkPolicyTest {
 static long now;
 static boolean busy, unknown;
 static final CallSafeNetworkPolicy policy = new CallSafeNetworkPolicy(() -> {
  if (unknown) throw new SecurityException("no telephony permission");
  return busy;
 }, () -> now);
 static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
 static void quiet() { for (int i=0; i<11; i++) { now+=3000; policy.sample(); } }
 static void blocked() throws Exception {
  try { policy.requireIdle(); throw new AssertionError("network mutation must be deferred"); }
  catch (CallSafeNetworkPolicy.Deferred expected) {}
 }
 public static void main(String[] args) throws Exception {
  blocked(); quiet(); policy.requireIdle();
  // The Android probe maps all ringing/dialing/active calls and non-normal audio to busy.
  for (String state : new String[]{"ringing", "dialing/early_media", "active", "audio_tail"}) {
   busy=true; now+=3000; blocked();
   busy=false; now+=3000; blocked(); // must not switch as soon as Telecom ends
   quiet(); policy.requireIdle();
  }
  unknown=true; blocked(); unknown=false; blocked(); quiet(); policy.requireIdle();
  now+=60_000; blocked(); // service suspend/restart cannot count unobserved time as idle
  quiet(); policy.requireIdle();
  now=1; blocked(); // monotonic clock reset
  System.out.println("CallSafeNetworkPolicyTest passed: call, early audio, unknown state and idle recovery");
 }
}
