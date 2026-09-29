package com.airsim.phonecontrol;

import java.io.Closeable;

final class VoWLANPeerLifecycle {
    @FunctionalInterface interface Work { void run() throws Exception; }
    @FunctionalInterface interface Failure { void handle(Exception error) throws Exception; }

    private VoWLANPeerLifecycle() {}

    static void run(Closeable peer, Work work, Failure failure) {
        try {
            work.run();
        } catch (Exception error) {
            try { failure.handle(error); }
            catch (Exception ignored) {}
        } finally {
            try { peer.close(); }
            catch (Exception ignored) {}
        }
    }
}
