package com.airsim.phonecontrol;

public final class RelayCommandRetryTests {
    private static void check(boolean ok, String detail) { if (!ok) throw new AssertionError(detail); }
    public static void main(String[] args) throws Exception {
        var retry = new RelayCommandRetryState();
        long now = 0;
        for (long expected : new long[]{3000,6000,12000,24000,48000,60000,60000}) {
            var d = retry.failed(now, 1000, new java.io.EOFException(), 0);
            check(d.delayMillis() == expected, "short connection resets failure tier");
            check(retry.remainingMillis(now + 1) == expected - 1, "shared cooldown");
            now += expected;
        }
        check(retry.failed(now,60000,new java.io.EOFException(),0).delayMillis()==3000,"stable reset");
        retry.reset();
        check(retry.failed(0,0,WebSocketPeerClose.decode(new byte[]{15,(byte)161}),0).delayMillis()>=60000,"replacement cooldown");
        check(retry.failed(60000,0,WebSocketPeerClose.decode(new byte[]{15,(byte)161}),0).delayMillis()>=120000,"replacement escalation");
        retry.reset();
        check(retry.failed(0,0,new RelayHTTPException(429,"",600000),0).delayMillis()==600000,"Retry-After must survive cap");
        check(retry.remainingMillis(-1)>=600000,"clock rollback must not bypass cooldown");
        retry.reset();
        check(retry.failed(0,0,new RelayHTTPException(503,""),1).delayMillis()==18750,"overload jitter");
        retry.reset();
        check(retry.failed(0,0,null,1).delayMillis()==3750,"ordinary jitter");
        retry.reset();
        check(retry.failed(0,0,null,Double.NaN).delayMillis()==3000,"NaN jitter");
        retry.reset();
        retry.failed(Long.MAX_VALUE-10,0,null,0);
        check(retry.remainingMillis(Long.MAX_VALUE-9)>0,"overflow cooldown");
        check(RelayHTTPException.parseRetryAfter("600",0)==600000,"seconds header");
        check(RelayHTTPException.parseRetryAfter("Thu, 01 Jan 1970 00:10:00 GMT",0)==600000,"date header");
        check(RelayHTTPException.parseRetryAfter("garbage",0)==0,"invalid header");
        check(!CommandPollingPolicy.shouldPoll(false,0,20000,1),"HTTP must share WSS cooldown");
        check(CloudCallTarget.requiresIdentity("dtmf") && CloudCallTarget.requiresIdentity("call_control")
            && !CloudCallTarget.requiresIdentity("dial"),"delayed tones must use the locked call, not any current Telecom call");
        long epoch = retry.configure("synthetic-A");
        int[] closes = {0};
        check(retry.attach(epoch, () -> closes[0]++),"attach current socket");
        check(retry.configure("synthetic-A")==epoch && closes[0]==0,"metadata unchanged scope");
        retry.configure("synthetic-B");
        check(closes[0]==1 && !retry.isCurrent(epoch),"identity change cancels old epoch");
        check(retry.failedFor(epoch,1000,0,new RelayHTTPException(429,""),0)==null
            && retry.remainingMillis(1000)==0,"stale failure changed new scope cooldown");
        check(!retry.attach(epoch, () -> closes[0]++) && closes[0]==2,"late handshake cannot revive old epoch");
        epoch = retry.configure("synthetic-B");
        retry.attach(epoch, () -> closes[0]++);
        retry.configure(null);
        check(!retry.isCurrent(epoch) && closes[0]==3,"cloud off or service stop closes socket");
        check(RelayCommandRetryState.validAgentID("安卓 /?%") && !RelayCommandRetryState.validAgentID(" ")
            && !RelayCommandRetryState.validAgentID("a\n") && !RelayCommandRetryState.validAgentID("\ud800")
            && !RelayCommandRetryState.validAgentID("中".repeat(43)),"bounded opaque identity");
        System.out.println("Relay command retry tests passed");
    }
}
