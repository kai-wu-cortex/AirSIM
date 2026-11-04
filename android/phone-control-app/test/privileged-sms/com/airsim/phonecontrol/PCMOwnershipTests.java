package com.airsim.phonecontrol;

import java.io.*;
import java.lang.reflect.*;
import java.util.concurrent.TimeUnit;

public final class PCMOwnershipTests {
    private static int checks;
    public static void main(String[] args) throws Exception {
        ShizukuBridgeUserService first = configured();
        ShizukuBridgeUserService second = configured();
        String firstFailure = startFailure(first);
        check(!firstFailure.contains("ownership already held"), "first owner could not reserve bridge");
        check(startFailure(second).contains("ownership already held"), "second supervisor entered PCM cleanup/start");
        Child child = new Child();
        set(first, "bridgeProcess", child);
        first.shutdown();
        first.shutdown();
        check(child.stops == 1 && !child.alive, "shutdown did not stop its child exactly once");
        check(startFailure(first).contains("service is stopping"), "late restart resurrected stopped supervisor");
        check(!startFailure(second).contains("ownership already held"), "handover did not release bridge lease");
        Method monitor = ShizukuBridgeUserService.class.getDeclaredMethod("monitorBridge", java.lang.Process.class);
        monitor.setAccessible(true);
        monitor.invoke(first, child);
        check(startFailure(first).contains("service is stopping"), "late process-exit monitor re-enabled bridge");
        second.shutdown();
        ShizukuBridgeUserService late = configured();
        startFailure(late);
        java.util.concurrent.atomic.AtomicReference<Throwable> failure = new java.util.concurrent.atomic.AtomicReference<>();
        Thread pendingRestart = new Thread(() -> {
            try { monitor.invoke(late, new Child()); }
            catch (Throwable error) { failure.set(error); }
        });
        pendingRestart.start();
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
        while (pendingRestart.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) Thread.sleep(5);
        check(pendingRestart.getState() == Thread.State.TIMED_WAITING, "did not reach queued restart delay");
        late.shutdown();
        pendingRestart.join(2500);
        check(!pendingRestart.isAlive() && failure.get() == null, "queued restart failed to finish: " + failure.get());
        Field desired = ShizukuBridgeUserService.class.getDeclaredField("bridgeDesired");
        desired.setAccessible(true);
        check(!desired.getBoolean(late), "restart captured before shutdown re-enabled the stopped supervisor");
        System.out.println("PCM ownership tests passed: " + checks + " assertions (no phone processes or audio)");
    }
    private static ShizukuBridgeUserService configured() throws Exception {
        var service = new ShizukuBridgeUserService();
        set(service, "sourceApk", "/test/airsim.apk");
        set(service, "packageName", "airsim.test.ownership");
        set(service, "standalonePCM", true);
        return service;
    }
    private static String startFailure(ShizukuBridgeUserService service) throws Exception {
        Method start = ShizukuBridgeUserService.class.getDeclaredMethod("ensureBridgeStarted");
        start.setAccessible(true);
        try { start.invoke(service); throw new AssertionError("test must not launch a real Android process"); }
        catch (InvocationTargetException error) {
            if (!(error.getCause() instanceof IOException)) throw error;
            return error.getCause().getMessage();
        }
    }
    private static void set(Object object, String name, Object value) throws Exception {
        Field field = object.getClass().getDeclaredField(name); field.setAccessible(true); field.set(object, value);
    }
    private static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    private static final class Child extends java.lang.Process {
        boolean alive = true; int stops;
        public OutputStream getOutputStream() { return new ByteArrayOutputStream(); }
        public InputStream getInputStream() { return new ByteArrayInputStream(new byte[0]); }
        public InputStream getErrorStream() { return getInputStream(); }
        public int waitFor() { return 0; }
        public boolean waitFor(long timeout, TimeUnit unit) { return !alive; }
        public int exitValue() { return 0; }
        public boolean isAlive() { return alive; }
        public void destroy() { stops++; alive = false; }
    }
}
