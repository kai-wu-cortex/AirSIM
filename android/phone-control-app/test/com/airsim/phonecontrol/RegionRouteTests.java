package com.airsim.phonecontrol;
public final class RegionRouteTests {
    public static void main(String[] args) {
        if (!VoWLANControlPolicy.allowed("POST", "/api/calls/regions")) throw new AssertionError("Missing region route");
        if (VoWLANControlPolicy.allowed("GET", "/api/calls/regions")) throw new AssertionError("Wrong method permitted");
        if (VoWLANControlPolicy.allowed("POST", "/api/calls/regions/other")) throw new AssertionError("Prefix admission");
        if (VoWLANControlPolicy.ownsCallAfterResponse("/api/calls/regions", 200, false)) throw new AssertionError("Query must not own a call");
        if (!VoWLANControlPolicy.ownsCallAfterResponse("/api/calls/regions", 200, true)) throw new AssertionError("Query must not release a call");
        System.out.println("RegionRouteTests passed");
    }
}
