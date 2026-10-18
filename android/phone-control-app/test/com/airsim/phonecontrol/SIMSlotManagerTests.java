package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Bundle;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import org.json.JSONArray;
import org.json.JSONObject;

public final class SIMSlotManagerTests {
    public static void main(String[] args) {
        testSlotParsing();
        testSlotInfoJSON();
        testRegisterListener();
        System.out.println("SIM slot manager tests passed");
    }

    private static void testRegisterListener() {
        Context context = new Context();
        context.setSystemService(android.telephony.SubscriptionManager.class, new android.telephony.SubscriptionManager());
        boolean[] triggered = new boolean[]{false};
        SIMSlotManager.registerChangeListener(context, () -> triggered[0] = true);
    }

    private static void testSlotParsing() {
        assertEquals(0, SIMSlotManager.parseSlotIdentifier("sim1"));
        assertEquals(0, SIMSlotManager.parseSlotIdentifier("SIM1"));
        assertEquals(0, SIMSlotManager.parseSlotIdentifier("slot1"));
        assertEquals(0, SIMSlotManager.parseSlotIdentifier("0"));

        assertEquals(1, SIMSlotManager.parseSlotIdentifier("sim2"));
        assertEquals(1, SIMSlotManager.parseSlotIdentifier("SIM2"));
        assertEquals(1, SIMSlotManager.parseSlotIdentifier("slot2"));
        assertEquals(1, SIMSlotManager.parseSlotIdentifier("1"));

        assertEquals(2, SIMSlotManager.parseSlotIdentifier("sim3"));
        assertEquals(-1, SIMSlotManager.parseSlotIdentifier("invalid"));
        assertEquals(-1, SIMSlotManager.parseSlotIdentifier(""));
        assertEquals(-1, SIMSlotManager.parseSlotIdentifier(null));
    }

    private static void testSlotInfoJSON() {
        SIMSlotInfo info = new SIMSlotInfo(
                0, 101, "中国移动", "SIM 1 · 中国移动", "+8613800000000",
                "CN", false, true, true, null);
        JSONObject json = info.toJSON();
        assertEquals("中国移动", json.optString("carrier_name", ""));
        assertEquals(0, json.optInt("slot_index", -1));
        assertEquals(101, json.optInt("sub_id", -1));
    }

    private static void assertEquals(int expected, int actual) {
        if (expected != actual) {
            throw new AssertionError("expected " + expected + " but was " + actual);
        }
    }

    private static void assertEquals(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected " + expected + " but was " + actual);
        }
    }
}
