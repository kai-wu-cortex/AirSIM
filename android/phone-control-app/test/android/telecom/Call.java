package android.telecom;

import android.os.Bundle;

public class Call {
    public static final int STATE_DIALING = 1;
    public static final int STATE_RINGING = 2;
    public static final int STATE_ACTIVE = 4;
    public static final int STATE_DISCONNECTING = 9;
    public static final int STATE_DISCONNECTED = 10;

    private int state;
    private Details details;
    private final java.util.List<Callback> callbacks = new java.util.concurrent.CopyOnWriteArrayList<>();
    public abstract static class Callback {
        public void onStateChanged(Call call, int state) {}
        public void onDetailsChanged(Call call, Details details) {}
    }
    public void registerCallback(Callback callback) { callbacks.add(callback); }
    public void unregisterCallback(Callback callback) { callbacks.remove(callback); }
    public void setStateForTest(int value) {
        state = value;
        for (Callback callback : callbacks) callback.onStateChanged(this, value);
    }
    public static final class Details {
        public static final int DIRECTION_INCOMING = 0;
        public static final int DIRECTION_OUTGOING = 1;
        private final int direction;
        private final android.net.Uri handle;
        Details(int direction, String number) { this.direction = direction; handle = android.net.Uri.parse("tel:" + number); }
        public int getCallDirection() { return direction; }
        public android.net.Uri getHandle() { return handle; }
        public PhoneAccountHandle getAccountHandle() { return null; }
        public Bundle getExtras() { return null; }
    }
    public Call(int state, int direction, String number) { this.state = state; details = new Details(direction, number); }
    public Details getDetails() { return details; }

    public Call(int state) { this.state = state; }

    public int getState() { return state; }

    public void answer(int videoState) { setStateForTest(STATE_ACTIVE); }

    public void reject(boolean withMessage, String textMessage) { setStateForTest(STATE_DISCONNECTED); }

    public void disconnect() { setStateForTest(STATE_DISCONNECTED); }

    public void playDtmfTone(char digit) {}

    public void stopDtmfTone() {}
}
