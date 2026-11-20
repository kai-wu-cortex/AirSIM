package com.airsim.phonecontrol;

import android.content.Context;
import android.database.Cursor;
import android.provider.CallLog;
import android.telephony.PhoneNumberUtils;

/** Read only an exact number's cached system attribution; never infer it from a contact name. */
final class AndroidNumberRegion {
    static String lookup(Context context, String number) {
        if (number == null || number.isBlank()) return "";
        String normalized = PhoneNumberUtils.normalizeNumber(number);
        if (normalized.isEmpty()) return "";
        try (Cursor cursor = context.getContentResolver().query(CallLog.Calls.CONTENT_URI,
                new String[]{CallLog.Calls.GEOCODED_LOCATION},
                CallLog.Calls.NUMBER + " = ? OR " + CallLog.Calls.CACHED_NORMALIZED_NUMBER + " = ?",
                new String[]{number, normalized}, CallLog.Calls.DATE + " DESC")) {
            for (int count = 0; cursor != null && count < 5 && cursor.moveToNext(); count++) {
                String value = cursor.getString(0);
                if (value != null && !value.isBlank() && value.length() <= 80
                        && value.chars().noneMatch(Character::isISOControl)) return value.trim();
            }
        } catch (RuntimeException ignored) {
            // Permission missing or OEM provider unavailable: leave the iPhone's offline fallback intact.
        }
        return "";
    }
}
