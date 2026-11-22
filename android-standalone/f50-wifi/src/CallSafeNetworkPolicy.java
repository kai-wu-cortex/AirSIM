package com.airsim.f50wifi;

import java.util.function.LongSupplier;

/** Requires continuously observed idle time, including after unknown/failed queries. */
final class CallSafeNetworkPolicy {
 interface Probe { boolean busy() throws Exception; }
 static final long QUIET_MILLIS = 30_000;
 static final long MAX_SAMPLE_GAP_MILLIS = 10_000;
 static final class Deferred extends Exception {
  Deferred() { super("通话或音频尚在使用，或状态无法确认；请结束通话并等待 30 秒后重试。"); }
 }
 private final Probe probe;
 private final LongSupplier clock;
 private long idleSince = -1, lastSample = -1;
 CallSafeNetworkPolicy(Probe probe, LongSupplier clock) { this.probe = probe; this.clock = clock; }
 synchronized boolean sample() {
  long now = clock.getAsLong();
  if (lastSample < 0 || now < lastSample || now - lastSample > MAX_SAMPLE_GAP_MILLIS) idleSince = -1;
  lastSample = now;
  try {
   if (probe.busy()) { idleSince = -1; return false; }
  } catch (Exception unavailable) { idleSince = -1; return false; }
  if (idleSince < 0) idleSince = now;
  return now - idleSince >= QUIET_MILLIS;
 }
 void requireIdle() throws Deferred { if (!sample()) throw new Deferred(); }
}
