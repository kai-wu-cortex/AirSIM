package com.airsim.f50wifi;

public final class DualSimPolicyTest {
 static final String SUPPORTED = "Result: Bundle[{supported=true, state=disabled}]";
 static final class Fake implements DualSimPolicy.Operations {
  boolean enabled, booted=true, trusted=true, idle=true, throwStatus, revoke;
  String status=SUPPORTED;
  int writes, pulses, queries;
  final java.util.List<String> order = new java.util.ArrayList<>();
  public boolean enabled(){return enabled;}
  public boolean booted(){return booted;}
  public boolean trusted(){return trusted;}
  public String status() throws Exception {
   queries++;order.add("status");
   if(throwStatus)throw new java.io.IOException("provider unavailable");
   if(revoke)enabled=false;
   return status;
  }
  public boolean idle(){return idle;}
  public void enable(){writes++;order.add("write");}
  public String pulse(){pulses++;order.add("pulse");return "Result: Bundle[{state=enabled, supported=true}]";}
 }
 static void check(boolean v,String m){if(!v)throw new AssertionError(m);}
 static void noWrite(Fake f)throws Exception {
  DualSimPolicy.tick(f); check(f.writes==0&&f.pulses==0,"must not mutate or pulse");
 }
 public static void main(String[] args)throws Exception {
  Fake f=new Fake();noWrite(f);check(f.queries==0,"default off: no provider access");
  f.enabled=true;f.trusted=false;noWrite(f);check(f.queries==0,"untrusted helper is never called");
  f.trusted=true;f.booted=false;noWrite(f);f.booted=true;
  for(String status:new String[]{"Result: Bundle[{supported=false, state=unsupported_firmware}]", "Error", "", "Result: Bundle[{unsupported=true}]", "Result: Bundle[{supported=true, supported=false}]"}){
   f.status=status;noWrite(f);
  }
  f.status=SUPPORTED;f.throwStatus=true;
  try{DualSimPolicy.tick(f);throw new AssertionError("expected provider failure");}catch(java.io.IOException expected){}
  check(f.writes==0,"failed status must not write");f.throwStatus=false;
  f.idle=false;noWrite(f);f.idle=true;f.revoke=true;noWrite(f);
  f=new Fake();f.enabled=true;
  check("keeping_enabled".equals(DualSimPolicy.tick(f)),"supported opt-in succeeds");
  check(f.order.equals(java.util.List.of("status","write","pulse")),"firmware preflight precedes every write");
  f.enabled=false;DualSimPolicy.tick(f);check(f.writes==1&&f.pulses==1,"disable stops supervision");
  System.out.println("DualSimPolicyTest passed: default off, firmware preflight, permission failure, busy and revocation");
 }
}
