package com.airsim.phonecontrol;

import java.io.*;
import java.util.concurrent.TimeUnit;

public final class RootSMSPreflightTests {
    static final class FakeProcess extends Process {
        final String output; final int exit; final boolean completes; boolean destroyed;
        FakeProcess(String output, int exit, boolean completes) { this.output=output; this.exit=exit; this.completes=completes; }
        public OutputStream getOutputStream() { return OutputStream.nullOutputStream(); }
        public InputStream getInputStream() { return new ByteArrayInputStream(output.getBytes()); }
        public InputStream getErrorStream() { return InputStream.nullInputStream(); }
        public int waitFor() { return exit; }
        public boolean waitFor(long n, TimeUnit unit) { return completes; }
        public int exitValue() { return exit; }
        public void destroy() { destroyed=true; }
        public Process destroyForcibly() { destroyed=true; return this; }
        public boolean isAlive() { return !completes && !destroyed; }
    }
    static void equal(Object expected,Object value) { if(!expected.equals(value)) throw new AssertionError(expected+" != "+value); }
    public static void main(String[] args) {
        equal("unavailable", RootSMSPreflight.check(() -> { throw new IOException("su absent"); },1));
        equal("unavailable", RootSMSPreflight.check(() -> new FakeProcess("denied",1,true),1));
        equal("unavailable", RootSMSPreflight.check(() -> new FakeProcess("2000",0,true),1));
        equal("unavailable", RootSMSPreflight.check(() -> new FakeProcess("",0,true),1));
        FakeProcess timed = new FakeProcess("",0,false);
        equal("unavailable", RootSMSPreflight.check(() -> timed,1));
        equal(true,timed.destroyed);
        equal("ready", RootSMSPreflight.check(() -> new FakeProcess("0\n",0,true),1));
        String before = RootSMSPreflight.launchFailure(false,new IOException());
        String after = RootSMSPreflight.launchFailure(true,new IOException());
        equal(true,SMSPrivilegedResult.mayFallback(before));
        equal(false,SMSPrivilegedResult.mayFallback(after));
        equal(false,SMSPrivilegedResult.mayFallback("error:no_result"));
        equal(false,SMSPrivilegedResult.mayFallback("error:timeout"));
        equal("unknown",SMSPrivilegedResult.diagnosticCode("arbitrary user text\n"));
        equal("error:send_unknown:IOException",SMSPrivilegedResult.diagnosticCode(after));
        System.out.println("RootSMSPreflightTests passed: missing/denied/unprivileged/timeout safe before dispatch; no retry after launch");
    }
}
