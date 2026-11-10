package com.airsim.phonecontrol;

import com.airsim.phonecontrol.voble.VoBLERecoveryRequest;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

public final class ServiceStartupTests {
    private static int checks;
    private static void check(boolean ok, String message) {
        checks++; if (!ok) throw new AssertionError(message);
    }
    public static void main(String[] args) throws Exception {
        ServiceStartGate gate = new ServiceStartGate();
        AtomicInteger launches = new AtomicInteger();
        CountDownLatch ready = new CountDownLatch(16), go = new CountDownLatch(1);
        Thread[] threads = new Thread[16];
        for (int i=0;i<threads.length;i++) {
            threads[i] = new Thread(() -> {
                ready.countDown();
                try { go.await(); } catch (InterruptedException e) { throw new AssertionError(e); }
                gate.request(() -> { launches.incrementAndGet(); return true; });
            });
            threads[i].start();
        }
        ready.await(); go.countDown(); for (Thread thread: threads) thread.join();
        check(launches.get()==1, "concurrent requests must issue one OS start");
        check(gate.request(() -> true)==ServiceStartGate.Result.PENDING, "await lifecycle acknowledgement");
        Object first = new Object(), second = new Object();
        gate.created(first);
        check(gate.request(() -> { throw new AssertionError("must not relaunch"); })==ServiceStartGate.Result.RUNNING,
            "running service is distinct from pending request");
        gate.destroyed(new Object());
        check(gate.request(() -> false)==ServiceStartGate.Result.RUNNING, "unrelated destruction cannot clear owner");
        gate.destroyed(first);
        check(gate.request(() -> false)==ServiceStartGate.Result.REJECTED, "null OS result resets pending");
        try { gate.request(() -> { throw new SecurityException("background denied"); }); throw new AssertionError(); }
        catch(SecurityException expected) {}
        check(gate.request(() -> true)==ServiceStartGate.Result.REQUESTED, "retry after platform denial");
        gate.created(second); gate.destroyed(first);
        check(gate.request(() -> false)==ServiceStartGate.Result.RUNNING, "late old destruction preserves new service");
        gate.destroyed(second);
        check(gate.request(() -> true)==ServiceStartGate.Result.REQUESTED, "restart after destruction");

        VoBLERecoveryRequest recovery = new VoBLERecoveryRequest();
        ArrayList<Runnable> main = new ArrayList<>();
        AtomicInteger attempts = new AtomicInteger();
        boolean[] alive = {true}, advertising = {false};
        Runnable repair = () -> { attempts.incrementAndGet(); advertising[0] = true; };
        for(int i=0;i<16;i++) recovery.request(main::add, () -> alive[0], repair);
        check(main.size()==1 && attempts.get()==0, "recovery coalesces and waits for main thread");
        main.remove(0).run();
        check(advertising[0] && attempts.get()==1, "foreground request retries exhausted advertising");
        advertising[0]=false;
        recovery.request(main::add, () -> alive[0], repair); main.remove(0).run();
        check(advertising[0] && attempts.get()==2, "later recovery remains available");
        recovery.request(main::add, () -> alive[0], repair); alive[0]=false; main.remove(0).run();
        check(attempts.get()==2, "destroyed service cannot recover from queued callback");
        alive[0]=true;
        recovery.request(task -> false, () -> true, repair);
        recovery.request(main::add, () -> true, repair);
        check(main.size()==1, "failed Handler post cannot wedge recovery"); main.remove(0).run();
        System.out.println("PASS ServiceStartupTests checks="+checks);
    }
}
