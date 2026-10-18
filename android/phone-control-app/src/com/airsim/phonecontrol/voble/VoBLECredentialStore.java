package com.airsim.phonecontrol.voble;

import java.util.Arrays;
import java.util.Base64;

/** The supplied backend must use Android private/encrypted preferences in production. */
public final class VoBLECredentialStore {
    public interface ProtectedBackend {
        String load(String key);
        void save(String key, String value);
        void remove(String key);
    }

    private static final String PREFIX = "voble.peer.";
    private final ProtectedBackend backend;

    public VoBLECredentialStore(ProtectedBackend backend) {
        this.backend = backend;
    }

    /** Uses Context.MODE_PRIVATE without taking an Android dependency in the protocol layer. */
    public static VoBLECredentialStore androidPrivatePreferences(Object context) {
        if (context == null) throw new IllegalArgumentException("context is required");
        return new VoBLECredentialStore(new ReflectiveAndroidPreferences(context));
    }

    public void save(String identity, byte[] pairingKey) {
        if (identity == null || identity.isEmpty() || pairingKey == null || pairingKey.length != 32) {
            throw new IllegalArgumentException("invalid VoBLE credential");
        }
        backend.save(PREFIX + identity,
                Base64.getUrlEncoder().withoutPadding().encodeToString(pairingKey));
    }

    public byte[] load(String identity) {
        String encoded = backend.load(PREFIX + identity);
        if (encoded == null || encoded.isEmpty()) return null;
        byte[] value = Base64.getUrlDecoder().decode(encoded);
        if (value.length != 32) {
            Arrays.fill(value, (byte) 0);
            return null;
        }
        return value;
    }

    public boolean hasCredential(String identity) {
        byte[] value = load(identity);
        if (value == null) return false;
        Arrays.fill(value, (byte) 0);
        return true;
    }

    public void revoke(String identity) {
        backend.remove(PREFIX + identity);
    }

    private static final class ReflectiveAndroidPreferences implements ProtectedBackend {
        private static final String FILE = "voble_credentials";
        private final Object preferences;

        ReflectiveAndroidPreferences(Object context) {
            try {
                preferences = context.getClass()
                        .getMethod("getSharedPreferences", String.class, int.class)
                        .invoke(context, FILE, 0);
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("Android private preferences unavailable", error);
            }
        }

        @Override public String load(String key) {
            try {
                return (String) Class.forName("android.content.SharedPreferences")
                        .getMethod("getString", String.class, String.class)
                        .invoke(preferences, key, "");
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("cannot read VoBLE credential", error);
            }
        }

        @Override public void save(String key, String value) {
            mutate("putString", new Class<?>[]{String.class, String.class}, key, value);
        }

        @Override public void remove(String key) {
            mutate("remove", new Class<?>[]{String.class}, key);
        }

        private void mutate(String method, Class<?>[] parameterTypes, Object... arguments) {
            try {
                Class<?> preferencesType = Class.forName("android.content.SharedPreferences");
                Class<?> editorType = Class.forName("android.content.SharedPreferences$Editor");
                Object editor = preferencesType.getMethod("edit").invoke(preferences);
                Object changed = editorType.getMethod(method, parameterTypes)
                        .invoke(editor, arguments);
                editorType.getMethod("apply").invoke(changed);
            } catch (ReflectiveOperationException error) {
                throw new IllegalStateException("cannot update VoBLE credential", error);
            }
        }
    }
}
