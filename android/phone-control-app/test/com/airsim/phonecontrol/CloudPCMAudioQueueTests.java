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
        System.out.println("CloudPCMAudioQueueTests passed");
    }
    private static int sample(byte[] frame) { return (short) ((frame[0] & 0xff) | (frame[1] << 8)); }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
