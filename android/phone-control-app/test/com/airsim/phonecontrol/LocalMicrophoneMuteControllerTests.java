package com.airsim.phonecontrol;
import java.io.IOException;
public final class LocalMicrophoneMuteControllerTests {
    private static final class Mic implements LocalMicrophoneMuteController.Backend {
        boolean value, ignoreMute, rejectRestore; int writes;
        public boolean muted() { return value; }
        public void setMuted(boolean target) throws IOException {
            writes++;
            if (!target && rejectRestore) throw new IOException("busy");
            if (!(target && ignoreMute)) value = target;
        }
    }
    public static void main(String[] args) throws Exception {
        for (boolean original : new boolean[]{false, true}) {
            Mic m = new Mic(); m.value = original;
            LocalMicrophoneMuteController c = new LocalMicrophoneMuteController(m);
            c.setMuted(true); check(m.value && c.verified(), "mute must be read back");
            m.value = false; c.setMuted(true); check(m.value, "native audio reset must be re-muted");
            c.setMuted(false); check(m.value == original && !c.verified(), "restore original user mic state");
            int before = m.writes; c.setMuted(false); check(m.writes == before, "idle release is read-only");
        }
        Mic refused = new Mic(); refused.ignoreMute = true;
        LocalMicrophoneMuteController c = new LocalMicrophoneMuteController(refused);
        try { c.setMuted(true); throw new AssertionError("ignored mute must fail"); } catch (IOException expected) {}
        check(!refused.value && !c.verified(), "refused writes cannot claim success");
        Mic m = new Mic(); c = new LocalMicrophoneMuteController(m); c.setMuted(true);
        m.rejectRestore = true;
        try { c.setMuted(false); throw new AssertionError("failed restore must surface"); } catch (IOException expected) {}
        m.rejectRestore = false; c.setMuted(false); check(!m.value, "restore retry retains original snapshot");
        System.out.println("Microphone isolation tests passed: original state, reassert, rejection, restore retry");
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
