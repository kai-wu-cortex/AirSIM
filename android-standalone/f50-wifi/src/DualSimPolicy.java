package com.airsim.f50wifi;

/** No vendor writes before explicit opt-in, signer and read-only firmware preflight. */
final class DualSimPolicy {
 interface Operations {
  boolean enabled() throws Exception;
  boolean booted() throws Exception;
  boolean trusted() throws Exception;
  String status() throws Exception;
  boolean idle() throws Exception;
  void enable() throws Exception;
  String pulse() throws Exception;
 }
 static boolean supported(String reply) {
  return field(reply, "supported", "true");
 }
 private static boolean field(String reply, String key, String value) {
  if (reply == null || !reply.trim().startsWith("Result: Bundle[{")) return false;
  var matcher = java.util.regex.Pattern.compile("(?:[\\{,]\\s*)" + key + "=([^,}]+)").matcher(reply);
  if (!matcher.find() || !value.equals(matcher.group(1).trim())) return false;
  return !matcher.find(); // ambiguous duplicate fields are not proof
 }
 static String tick(Operations ops) throws Exception {
  if (!ops.enabled()) return "disabled";
  if (!ops.booted()) return "waiting_for_boot";
  if (!ops.trusted()) return "helper_not_trusted";
  if (!supported(ops.status())) return "unsupported_or_unknown_firmware";
  if (!ops.idle()) return "waiting_for_idle";
  // Owner can remove the opt-in while status/permission checks are in flight.
  if (!ops.enabled()) return "disabled";
  ops.enable();
  String result = ops.pulse();
  return supported(result) && field(result, "state", "enabled") ? "keeping_enabled" : "needs_attention";
 }
}
