package com.airsim.f50wifi;

import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.concurrent.*;

/** Opt-in supervision of the already-installed, certificate-pinned AirSIM helper. */
final class AirSimSupervisor {
 static final String PACKAGE="com.airsim.phonecontrol.standalone";
 static final File TOKEN=new File("/data/local/tmp/airsim-bridge.token");
 final F50WifiServer server;
 final ScheduledExecutorService worker=Executors.newSingleThreadScheduledExecutor();
 volatile String state="disabled"; volatile boolean healthy; volatile int starts;
 volatile String dialerState="disabled"; volatile boolean dialerReady;
 long lastStart; String lastReported="";
 String lastDialerReported="";
 AirSimSupervisor(F50WifiServer server){this.server=server;}
 File data(String name){return new File(server.directory,name);}
 boolean enabled(){return data("airsim-autostart.enabled").isFile();}
 JSONObject status()throws Exception {return new JSONObject().put("enabled",enabled()).put("healthy",healthy).put("state",state).put("starts_this_process",starts)
  .put("default_dialer_enabled",data("airsim-default-dialer.enabled").isFile()).put("default_dialer_ready",dialerReady).put("default_dialer_state",dialerState);}
 void start(){worker.scheduleWithFixedDelay(this::tick,2,15,TimeUnit.SECONDS);}
 static boolean ordinary(File file)throws IOException {return !Files.isSymbolicLink(file.toPath())&&file.getCanonicalFile().equals(file.getAbsoluteFile());}
 String packageApk()throws Exception {
  File pin=data("airsim-package-signer.sha256");
  if(!pin.isFile()||!ordinary(pin))throw new IOException("signer pin unavailable");
  PackageInfo info=server.context.getPackageManager().getPackageInfo(PACKAGE,PackageManager.GET_SIGNING_CERTIFICATES);
  if(info.signingInfo==null||info.signingInfo.getApkContentsSigners().length!=1)throw new IOException("unsupported signer set");
  byte[] digest=MessageDigest.getInstance("SHA-256").digest(info.signingInfo.getApkContentsSigners()[0].toByteArray());
  StringBuilder actual=new StringBuilder();for(byte b:digest)actual.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
  if(!PortalRules.same(actual.toString(),F50WifiServer.read(pin).trim()))throw new IOException("signer mismatch");
  return server.context.getPackageManager().getApplicationInfo(PACKAGE,0).sourceDir;
 }
 String existingToken()throws Exception {
  File backup=data("airsim-daemon.token");
  if(!ordinary(TOKEN)||!ordinary(backup))throw new IOException("token path not ordinary");
  if(TOKEN.isFile()){
   if(TOKEN.length()>256)throw new IOException("token too large");
   String value=F50WifiServer.read(TOKEN).trim();
   if(value.length()<16||value.length()>256||value.indexOf('\n')>=0)throw new IOException("invalid existing token");
   if(!backup.isFile()||!PortalRules.same(F50WifiServer.read(backup).trim(),value)){
    File temp=data("airsim-daemon.token.new");if(!ordinary(temp))throw new IOException("backup path not ordinary");
    F50WifiServer.write(temp,value);if(!temp.renameTo(backup))throw new IOException("backup rename failed");
   }
   return value;
  }
  // The legacy app reads this fixed path. Restore the same credential after
  // vendor tmp cleanup; never generate/rotate credentials or broaden access.
  if(!backup.isFile()||backup.length()>256)throw new IOException("existing token unavailable");
  String value=F50WifiServer.read(backup).trim();if(value.length()<16||value.indexOf('\n')>=0)throw new IOException("invalid backup token");
  File temp=new File(TOKEN.getPath()+".autostart-new");if(!ordinary(temp))throw new IOException("restore path not ordinary");
  F50WifiServer.write(temp,value);
  // Match the existing daemon token's 0644 permissions for the app reader.
  if(!temp.setReadable(true,false)||!temp.renameTo(TOKEN))throw new IOException("token restore failed");
  F50WifiServer.run("restorecon",TOKEN.getPath());return value;
 }
 boolean probe(String token){try(Socket socket=new Socket()){
  socket.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(),27580),1000);socket.setSoTimeout(2000);
  socket.getOutputStream().write((new JSONObject().put("op","status").put("token",token)+"\n").getBytes(StandardCharsets.UTF_8));
  ByteArrayOutputStream line=new ByteArrayOutputStream();InputStream input=socket.getInputStream();
  for(int i=0;i<8192;i++){int c=input.read();if(c<0)return false;if(c=='\n'){JSONObject reply=new JSONObject(line.toString("UTF-8"));String result=reply.optString("result");return !reply.has("error")&&(result.startsWith("uid=2000 ")||result.startsWith("uid=0 "));}line.write(c);}
 }catch(Exception ignored){}return false;}
 void ensureDefaultDialer(){try{
  // B28 can omit ROLE_DIALER entirely. Its shell-only Telecom override is
  // memory-only, so the owner may opt in to restoring an empty default at boot.
  // Called only after APK certificate verification. Preserve another chosen app.
  if(!data("airsim-default-dialer.enabled").isFile()){dialerReady=false;dialerState="disabled";return;}
  String current=F50WifiServer.run("cmd","telecom","get-default-dialer");
  if(PACKAGE.equals(current)){dialerReady=true;dialerState="ready";return;}
  dialerReady=false;
  if(!current.isEmpty()&&!current.equals("null")){dialerState="other_default_preserved";return;}
  F50WifiServer.run("cmd","telecom","set-default-dialer",PACKAGE);
  dialerReady=PACKAGE.equals(F50WifiServer.run("cmd","telecom","get-default-dialer"));
  dialerState=dialerReady?"ready":"not_applied";
 }catch(Exception ignored){dialerReady=false;dialerState="unavailable";}
 finally{if(!dialerState.equals(lastDialerReported)){System.out.println("airsim_default_dialer state="+dialerState);lastDialerReported=dialerState;}}}
 void tick(){try{
  if(!enabled()){healthy=false;state="disabled";dialerReady=false;dialerState="disabled";return;}
  if(!F50WifiServer.run("getprop","sys.boot_completed").equals("1")){state="waiting_for_boot";return;}
  String apk=packageApk(),token=existingToken();ensureDefaultDialer();healthy=probe(token);
  if(healthy){state="ready";return;}
  // Do not kill an existing bridge or its media session on a slow response.
  if(!F50WifiServer.run("pidof","airsim-root-bridge").isEmpty()){state="waiting_for_bridge";return;}
  long now=android.os.SystemClock.elapsedRealtime();if(lastStart!=0&&now-lastStart<45000){state="retry_pending";return;}
  File log=data("airsim-bridge.log");if(!ordinary(log))throw new IOException("log path not ordinary");
  if(log.length()>65536&&!log.renameTo(data("airsim-bridge.previous.log")))throw new IOException("log rotation failed");
  ProcessBuilder launch=new ProcessBuilder("/system/bin/app_process","/system/bin","--nice-name=airsim-root-bridge","com.airsim.phonecontrol.RootBridgeMain",PACKAGE,"27580",TOKEN.getPath());
  launch.environment().put("CLASSPATH",apk);launch.redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.appendTo(log));
  launch.start();lastStart=now;starts++;state="starting";
 }catch(Exception e){healthy=false;state="needs_attention";}
 finally{if(!state.equals(lastReported)){System.out.println("airsim_autostart state="+state+" starts="+starts);lastReported=state;}}}
}
