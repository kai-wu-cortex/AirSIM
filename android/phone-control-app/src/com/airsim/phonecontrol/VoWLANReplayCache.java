package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public final class VoWLANReplayCache {
    private final long retentionSeconds;
    private final Map<String, Long> seen = new HashMap<>();

    public VoWLANReplayCache(long retentionSeconds) {
        if (retentionSeconds < 1) throw new IllegalArgumentException("retention must be positive");
        this.retentionSeconds = retentionSeconds;
    }

    public synchronized boolean accept(String nonce, long nowSeconds) {
        if (nonce == null || nonce.length() < 7 || nonce.length() > 128) return false;
        Iterator<Map.Entry<String, Long>> iterator = seen.entrySet().iterator();
        while (iterator.hasNext()) {
            if (nowSeconds - iterator.next().getValue() > retentionSeconds) iterator.remove();
        }
        if (seen.containsKey(nonce)) return false;
        seen.put(nonce, nowSeconds);
        return true;
    }
}
