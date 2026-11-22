package com.airsim.f50wifi;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import org.json.JSONObject;
import java.io.*;
import java.security.MessageDigest;
import java.util.concurrent.*;

/** Explicit owner opt-in; keeps B28's no-service timer deferred, never powers a SIM off. */
final class DualSimSupervisor {
 static final String PACKAGE="com.airsim.f50dsds";
 final F50WifiServer server;
 final ScheduledExecutorService worker=Executors.newSingleThreadScheduledExecutor();
 volatile String state="disabled";volatile boolean ready;volatile int pulses;
 String lastReported="";
 DualSimSupervisor(F50WifiServer server){this.server=server;}
 File data(String name){return new File(server.directory,name);}
 boolean enabled(){try{return data("dsds-keep-enabled").isFile()&&AirSimSupervisor.ordinary(data("dsds-keep-enabled"));}catch(IOException invalid){return false;}}
 JSONObject status()throws Exception{return new JSONObject().put("enabled",enabled()).put("ready",ready).put("state",state).put("pulses_this_process",pulses);}
 void start(){worker.scheduleWithFixedDelay(this::tick,2,15,TimeUnit.SECONDS);}
 boolean trusted()throws Exception{
  File pin=data("dsds-helper-signer.sha256");if(!pin.isFile()||!AirSimSupervisor.ordinary(pin))return false;
  PackageInfo info=server.context.getPackageManager().getPackageInfo(PACKAGE,PackageManager.GET_SIGNING_CERTIFICATES);
  if(info.signingInfo==null||info.signingInfo.getApkContentsSigners().length!=1)return false;
  byte[] digest=MessageDigest.getInstance("SHA-256").digest(info.signingInfo.getApkContentsSigners()[0].toByteArray());
  StringBuilder hex=new StringBuilder();for(byte b:digest)hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
  return PortalRules.same(F50WifiServer.read(pin).trim(),hex.toString());
 }
 void tick(){try{
  ready=false;
  state=DualSimPolicy.tick(new DualSimPolicy.Operations(){
   public boolean enabled(){return DualSimSupervisor.this.enabled();}
   public boolean booted()throws Exception{return F50WifiServer.run("getprop","sys.boot_completed").equals("1");}
   public boolean trusted()throws Exception{return DualSimSupervisor.this.trusted();}
   public String status()throws Exception{return F50WifiServer.run("content","call","--uri","content://"+PACKAGE,"--method","status");}
   public boolean idle(){return server.callSafety.sample();}
   public void enable()throws Exception{
    // Firmware support was confirmed without side effects before this shell-only write.
    F50WifiServer.run("settings","put","system","car_mode_dual_sim_switch","1");
   }
   public String pulse()throws Exception{return F50WifiServer.run("content","call","--uri","content://"+PACKAGE,"--method","pulse");}
  });
  ready=state.equals("keeping_enabled");if(ready)pulses++;
 }catch(Exception ignored){ready=false;state="unavailable";}
 finally{if(!state.equals(lastReported)){System.out.println("dsds_keep_enabled state="+state);lastReported=state;}}}
}
