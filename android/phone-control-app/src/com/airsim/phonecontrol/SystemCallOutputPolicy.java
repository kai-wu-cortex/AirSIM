package com.airsim.phonecontrol;

import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Resolve actual framework methods in the privileged process, never hard-code Binder transactions. */
final class SystemCallOutputPolicy implements CallOutputPolicyMute.Api {
    private final Method getter, setter;
    private final boolean explicitMute;

    SystemCallOutputPolicy() throws Exception { this(Class.forName("android.media.AudioSystem")); }
    SystemCallOutputPolicy(Class<?> audioSystem) throws Exception {
        getter = audioSystem.getMethod("getStreamVolumeIndex", int.class, int.class);
        Method resolved;
        boolean flag;
        try {
            resolved = audioSystem.getMethod("setStreamVolumeIndexAS", int.class, int.class, boolean.class, int.class);
            flag = true;
        } catch (NoSuchMethodException oldPlatform) {
            resolved = audioSystem.getMethod("setStreamVolumeIndexAS", int.class, int.class, int.class);
            flag = false;
        }
        setter = resolved;
        explicitMute = flag;
    }
    public int index(int device) throws Exception {
        return ((Number) invoke(getter, 0, device)).intValue();
    }
    public void set(int device, int index, boolean muted) throws Exception {
        Object result = explicitMute ? invoke(setter, 0, index, muted, device)
                : invoke(setter, 0, index, device);
        if (!(result instanceof Number status) || status.intValue() != 0)
            throw new IOException("call policy command rejected");
    }
    private static Object invoke(Method method, Object... args) throws Exception {
        try { return method.invoke(null, args); }
        catch (InvocationTargetException error) {
            if (error.getCause() instanceof Exception cause) throw cause;
            throw new IOException("call policy invocation failed", error.getCause());
        }
    }
}
