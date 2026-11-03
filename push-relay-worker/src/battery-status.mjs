export function batteryStatus(value, now = Date.now()) {
  if (!value || !Number.isInteger(value.percent) || value.percent < 0 || value.percent > 100
      || typeof value.charging !== "boolean" || !Number.isFinite(value.observed_at_ms)
      || value.observed_at_ms <= 0 || now - value.observed_at_ms >= 300_000
      || value.observed_at_ms - now > 60_000) return null;
  return { percent: value.percent, charging: value.charging, observed_at_ms: value.observed_at_ms };
}
