package com.airsim.phonecontrol;
public class RemoteCallScreenPolicyTests {
 public static void main(String[] args) {
  var app = new RemoteCallScreenPolicy.Wake(true, 1000, 2);
  check(RemoteCallScreenPolicy.suppress(app, 900, 1050), "fresh application wake");
  for(int reason=0;reason<20;reason++)if(reason!=2)
   check(!RemoteCallScreenPolicy.suppress(new RemoteCallScreenPolicy.Wake(true,1000,reason),900,1050),"manual/non-application wake "+reason);
  check(!RemoteCallScreenPolicy.suppress(app,900,3000),"stale wake");
  check(!RemoteCallScreenPolicy.suppress(app,900,999),"future evidence");
  check(!RemoteCallScreenPolicy.suppress(app,3000,3100),"unrelated previous wake");
  check(!RemoteCallScreenPolicy.suppress(new RemoteCallScreenPolicy.Wake(false,1000,2),900,1050),"already off");
  check(RemoteCallScreenPolicy.eligible(true,true,false),"initially off remote");
  check(!RemoteCallScreenPolicy.eligible(false,true,false),"local mode");
  check(!RemoteCallScreenPolicy.eligible(true,false,false),"already using phone");
  check(RemoteCallScreenPolicy.scopeAllows(true,true,1,false),"exact active owner");
  check(!RemoteCallScreenPolicy.scopeAllows(true,true,2,false),"other call present");
  check(RemoteCallScreenPolicy.scopeAllows(true,true,0,true),"bounded teardown grace");
  check(!RemoteCallScreenPolicy.scopeAllows(true,true,1,true),"new call cancels teardown guard");
  var parsed=RemoteCallScreenPolicy.parse("  mWakefulness=Awake\n  mLastWakeTime=1000 (50 ms ago)\nmLastWakeReason=2\n");
  check(parsed.interactive() && parsed.time()==1000 && parsed.reason()==2,"actual Oplus power dump");
  try { RemoteCallScreenPolicy.parse("unavailable");throw new AssertionError("must fail closed"); }catch(IllegalArgumentException expected){}
  System.out.println("PASS: application-only wake, manual override, local mode, concurrent call and grace boundaries");
 }
 static void check(boolean b,String m){if(!b)throw new AssertionError(m);}
}
