package com.airsim.phonecontrol;

import android.content.Context;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/**
 * Stores paired VoWLAN clients. The old implementation had one global
 * "secret_v1"; a second pairing overwrote it and invalidated every previous
 * iPhone. Records are keyed by a fingerprint of the client-generated secret so
 * multiple clients can stay paired while the legacy secret is still accepted.
 */
public final class VoWLANPairingStore {
    private static final String FILE = "vowlan_pairing";
    private static final String LEGACY_SECRET = "secret_v1";
    private static final String RECORDS = "records_v2";
    private static final String LEGACY_MIGRATED = "legacy_migrated_v2";
    private static final int MAX_RECORDS = 16;

    private VoWLANPairingStore() {}

    public static final class Record {
        private final String id;
        private final byte[] secret;
        private final long createdAtMillis;
        private final long lastSeenMillis;

        private Record(String id, byte[] secret, long createdAtMillis, long lastSeenMillis) {
            this.id = id;
            this.secret = secret;
            this.createdAtMillis = createdAtMillis;
            this.lastSeenMillis = lastSeenMillis;
        }

        public String id() { return id; }
        public long createdAtMillis() { return createdAtMillis; }
        public long lastSeenMillis() { return lastSeenMillis; }
        public byte[] secretCopy() { return secret.clone(); }
    }

    /** Adds or refreshes one paired client; never replaces other clients. */
    public static synchronized void saveEncoded(Context context, String encoded) {
        byte[] decoded = decode(encoded);
        try {
            List<Record> values = records(context);
            String id = fingerprint(decoded);
            long now = System.currentTimeMillis();
            values.removeIf(record -> record.id.equals(id));
            values.add(new Record(id, decoded.clone(), now, now));
            values.sort(Comparator.comparingLong(Record::lastSeenMillis).reversed());
            if (values.size() > MAX_RECORDS) {
                values = new ArrayList<>(values.subList(0, MAX_RECORDS));
            }
            write(context, values);
        } finally {
            Arrays.fill(decoded, (byte) 0);
        }
    }

    public static synchronized List<Record> records(Context context) {
        List<Record> values = read(context);
        boolean migrated = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getBoolean(LEGACY_MIGRATED, false);
        if (!migrated) {
            byte[] legacy = legacySecret(context);
            if (legacy.length >= 32) {
                String id = fingerprint(legacy);
                if (values.stream().noneMatch(record -> record.id.equals(id))) {
                    long now = System.currentTimeMillis();
                    values.add(new Record(id, legacy.clone(), now, now));
                    values.sort(Comparator.comparingLong(Record::lastSeenMillis).reversed());
                }
            }
            Arrays.fill(legacy, (byte) 0);
            write(context, values);
            context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
                    .putBoolean(LEGACY_MIGRATED, true).apply();
        }
        return values;
    }

    /** Compatibility for callers that only need one configured secret. */
    public static byte[] load(Context context) {
        List<Record> values = records(context);
        if (values.isEmpty()) return new byte[0];
        return values.get(0).secretCopy();
    }

    /** Returns the record whose secret signed this request, or null. */
    public static Record match(
            Context context, String signature, String canonical, long timestamp, long now) {
        for (Record record : records(context)) {
            byte[] secret = record.secretCopy();
            try {
                if (VoWLANAuth.verify(secret, signature, canonical, timestamp, now)) return record;
            } finally {
                Arrays.fill(secret, (byte) 0);
            }
        }
        return null;
    }

    static Record matchWatch(Context context, String signature, String canonical, long timestamp, long now) {
        for (Record record : records(context)) {
            byte[] root = record.secretCopy();
            byte[] watch = VoWLANAuth.watchCallKey(root);
            try {
                if (VoWLANAuth.verify(watch, signature, canonical, timestamp, now)) return record;
            } finally {
                Arrays.fill(root, (byte) 0);
                Arrays.fill(watch, (byte) 0);
            }
        }
        return null;
    }

    public static boolean configured(Context context) {
        return !records(context).isEmpty();
    }

    public static void clear(Context context) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
                .remove(LEGACY_SECRET).remove(RECORDS).remove(LEGACY_MIGRATED).apply();
    }

    private static List<Record> read(Context context) {
        String encoded = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getString(RECORDS, "");
        List<Record> values = new ArrayList<>();
        if (encoded.isEmpty()) return values;
        try {
            JSONArray array = new JSONArray(encoded);
            for (int index = 0; index < array.length(); index++) {
                JSONObject item = array.optJSONObject(index);
                if (item == null) continue;
                byte[] secret;
                try { secret = decode(item.optString("secret", "")); }
                catch (IllegalArgumentException error) { continue; }
                String id = item.optString("id", "");
                if (id.isEmpty() || !id.equals(fingerprint(secret))) {
                    Arrays.fill(secret, (byte) 0);
                    continue;
                }
                values.add(new Record(id, secret,
                        item.optLong("created_at", 0), item.optLong("last_seen", 0)));
            }
        } catch (Exception ignored) {
            // A corrupt record must not block the legacy secret migration.
        }
        return values;
    }

    private static void write(Context context, List<Record> values) {
        JSONArray array = new JSONArray();
        for (Record record : values) {
            try {
                array.put(new JSONObject()
                        .put("id", record.id)
                        .put("secret", Base64.encodeToString(record.secret,
                                Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING))
                        .put("created_at", record.createdAtMillis)
                        .put("last_seen", record.lastSeenMillis));
            } catch (Exception ignored) {
                // Skip an unencodable record rather than losing all pairings.
            }
        }
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit()
                .putString(RECORDS, array.toString()).apply();
    }

    private static byte[] legacySecret(Context context) {
        String encoded = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
                .getString(LEGACY_SECRET, "");
        if (encoded.isEmpty()) return new byte[0];
        try { return decode(encoded); }
        catch (IllegalArgumentException error) { return new byte[0]; }
    }

    private static String fingerprint(byte[] secret) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(secret);
            StringBuilder value = new StringBuilder();
            for (byte item : digest) value.append(String.format("%02x", item & 0xff));
            return value.toString();
        } catch (Exception error) {
            throw new IllegalStateException("SHA-256 unavailable", error);
        }
    }

    private static byte[] decode(String encoded) {
        byte[] value = Base64.decode(encoded, Base64.NO_WRAP | Base64.URL_SAFE | Base64.NO_PADDING);
        if (value.length < 32) {
            Arrays.fill(value, (byte) 0);
            throw new IllegalArgumentException("VoWLAN secret too short");
        }
        return value;
    }
}
