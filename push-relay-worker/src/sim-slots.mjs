// Android DefaultCallAccount serializes ComponentName, opaque account ID and
// UserHandle.toString() with exactly two LF separators. Preserve bytes: the ID
// is used for exact account matching and command-intent deduplication.
export function validSIMAccountID(value) {
  if (typeof value !== "string" || !value.trim() ||
      new TextEncoder().encode(value).length > 512 ||
      /[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029]/.test(value)) return false;
  if (!value.includes("\n")) return true; // Existing opaque single-line IDs.
  const parts = value.split("\n");
  return parts.length === 3 &&
    /^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\/\.?[A-Za-z_$][A-Za-z0-9_.$]*$/.test(parts[0]) &&
    parts[1].trim().length > 0 && /^UserHandle\{[0-9]+\}$/.test(parts[2]);
}

// Bound display metadata from authenticated Agent heartbeats. IDs are opaque
// Telecom handles, never phone numbers or authorization credentials.
export function simSlots(value) {
  const seen = new Set();
  const text = (v, max) => typeof v === "string" &&
    new TextEncoder().encode(v).length <= max && !/[\u0000-\u001f\u007f]/.test(v);
  return value.slice(0, 8).flatMap(slot => {
    if (!slot || !validSIMAccountID(slot.id) || seen.has(slot.id) ||
        !text(slot.label, 256)) return [];
    seen.add(slot.id);
    const result = { id: slot.id, label: slot.label };
    for (const key of ["number", "carrier_name"]) {
      if (text(slot[key], 256)) result[key] = slot[key];
    }
    for (const key of ["default", "is_embedded", "is_default_voice", "is_default_sms"]) {
      if (typeof slot[key] === "boolean") result[key] = slot[key];
    }
    for (const key of ["slot_index", "sub_id"]) {
      if (Number.isSafeInteger(slot[key]) && slot[key] >= -1) result[key] = slot[key];
    }
    const signal = slot.signal;
    if (signal && Number.isInteger(signal.level) && signal.level >= 0 && signal.level <= 4 &&
        Number.isSafeInteger(signal.observed_at_ms) && signal.observed_at_ms > 0) {
      result.signal = { level: signal.level, observed_at_ms: signal.observed_at_ms };
    }
    return [result];
  });
}
