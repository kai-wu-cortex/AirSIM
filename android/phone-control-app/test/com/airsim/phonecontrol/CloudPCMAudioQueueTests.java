package com.airsim.phonecontrol;

public final class CloudPCMAudioQueueTests {
    public static void main(String[] args) {
        CloudPCMAudioQueue play = new CloudPCMAudioQueue(true);
        byte[] pcm = new byte[320];
        for (int sample = 0; sample < 160; sample++) {
            pcm[sample * 2] = (byte) 0xe8; pcm[sample * 2 + 1] = 3; // 1000
        }
        for (int i = 0; i < 3; i++) play.offer(pcm, i * 20);
        check(play.poll(40) == null, "prime a small reserve before playout");
        play.offer(pcm, 60);
        for (int i = 0; i < 4; i++) check(play.poll(60 + i * 20) != null, "play primed speech");
        byte[] concealed = play.poll(140);
        check(concealed != null && sample(concealed) < 1000 && sample(concealed) > 0,
                "short gaps need decaying concealment, not a new long buffering pause");
        check(play.poll(160) != null, "conceal up to two frames");
        check(play.poll(180) == null, "long outage must not loop old speech");
        check(play.concealedFrames() == 2 && play.underruns() == 3, "classify playout shortages");
        int raised = play.targetFrames();
        for (int i = 0; i < 500; i++) { play.offer(pcm, 200 + i * 20); play.poll(200 + i * 20); }
        check(play.targetFrames() < raised, "delay must recover after stable arrivals");
        CloudPCMAudioQueue burst = new CloudPCMAudioQueue(true);
        for (int i = 0; i < 12; i++) burst.offer(pcm, 0);
        for (int i = 1; i <= 200; i++) { burst.offer(pcm, i * 20); burst.poll(i * 20); }
        check(burst.size() <= 6, "actual backlog, not only target, must fall after stable arrivals");

        CloudPCMAudioQueue send = new CloudPCMAudioQueue(false);
        for (int i = 0; i < 100; i++) { byte[] frame = pcm.clone(); frame[0] = (byte) i; send.offer(frame, 0); }
        check(send.size() == 12 && send.droppedFrames() == 88, "bound backlog to 240 ms");
        check((send.poll(0)[0] & 0xff) == 88, "overflow keeps recent speech");
        check(send.poll(500) == null && send.size() == 0, "never send half-second-old speech");
        send.offer(pcm, 600); pcm[0] = 0;
        check(sample(send.poll(600)) == 1000, "queue owns its captured PCM");
        send.offer(new byte[319], 700);
        check(send.size() == 0, "reject partial PCM frames");
        check(CloudPCMAudioQueue.nextTickNanos(0, 1_000_000) == 20_000_000, "regular 20 ms cadence");
        check(CloudPCMAudioQueue.nextTickNanos(0, 500_000_000) == 520_000_000,
                "blocked socket must not cause catch-up bursts");
        bufferPreferences();
        System.out.println("CloudPCMAudioQueueTests passed");
    }
    private static void bufferPreferences() {
        var policy = CloudPCMAudioQueue.Policy.fromWire(1, "manual", 720);
        var manual = new CloudPCMAudioQueue(true, policy);
        byte[] pcm = new byte[320];
        for (int i = 0; i < 35; i++) {
            manual.offer(pcm, i * 20);
            check(manual.poll(i * 20) == null, "manual waits for 36 frames");
        }
        manual.offer(pcm, 700);
        for (int i = 0; i < 20; i++) check(manual.poll(720 + i * 20) != null, "buffer absorbs 400ms arrival gap");
        check(manual.underruns() == 0 && manual.size() == 16, "gap uses real buffered audio");
        for (int i = 0; i < 30; i++) manual.poll(1200 + i * 20);
        check(manual.targetFrames() == 36, "manual target does not grow on outage");
        manual.clear();
        for (int i = 0; i < 300; i++) manual.offer(pcm, 2000 + i * 20);
        check(manual.size() == 38 && manual.targetFrames() == 36, "manual memory and latency bounded");
        var stable = new CloudPCMAudioQueue(true, CloudPCMAudioQueue.Policy.fromWire(1, "stable", 0));
        for (int i = 0; i < 100; i++) stable.offer(pcm, i * 1000);
        check(stable.targetFrames() == 36 && stable.size() <= 38, "stable mode tolerates larger jitter");
        for (int i = 0; i < 3000; i++) { stable.offer(pcm, 100000 + i * 20); stable.poll(100000 + i * 20); }
        check(stable.targetFrames() == 12 && stable.size() <= 14, "stable mode recovers its baseline");
        check(CloudPCMAudioQueue.Policy.fromWire(0, "manual", 720).minimum == 4, "old client defaults to auto");
        check(CloudPCMAudioQueue.Policy.fromWire(1, "manual", Integer.MAX_VALUE).minimum == 4, "invalid wire value rejected");
        check(CloudPCMAudioQueue.Policy.fromWire(1, "unknown", 720).minimum == 4, "unknown mode rejected");
        var capture = new CloudPCMAudioQueue(false, policy);
        capture.offer(pcm, 0);
        check(capture.poll(0) != null, "large playback reserve never delays microphone capture");
        for (int i = 0; i < 100; i++) capture.offer(pcm, 0);
        check(capture.size() == 12 && capture.poll(500) == null, "capture backlog and age remain unchanged");
    }
    private static int sample(byte[] frame) { return (short) ((frame[0] & 0xff) | (frame[1] << 8)); }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
