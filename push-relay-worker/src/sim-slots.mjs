// Bound display metadata from authenticated Agent heartbeats. IDs are opaque
// Telecom handles, never phone numbers or authorization credentials.
export function simSlots(value) {
  const seen = new Set();
  const text = (v, max) => typeof v === "string" &&
    new TextEncoder().encode(v).length <= max && !/[\u0000-\u001f\u007f]/.test(v);
  return value.slice(0, 8).flatMap(slot => {
    if (!slot || !text(slot.id, 512) || !slot.id.trim() || seen.has(slot.id) ||
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
    return [result];
  });
}
