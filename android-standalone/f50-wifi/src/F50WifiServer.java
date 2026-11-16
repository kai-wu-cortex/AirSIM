package com.airsim.f50wifi;

import android.content.Context;
import android.net.wifi.*;
import android.os.Looper;
import org.json.*;
import java.io.*;
import java.lang.reflect.Proxy;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

/** MU3356-specific local Wi-Fi setup. Runs as shell; never changes USB or SIM settings. */
public final class F50WifiServer {
 final Context context; final WifiManager wifi; final File directory;
 final ScheduledExecutorService control=Executors.newSingleThreadScheduledExecutor();
 final Object storageLock=new Object();
 volatile String mode="starting",message="正在准备网络服务",lastError="";
 volatile long attemptStarted=0,disconnectedAt=0,hotspotSince=0,lastVisit=0;
 volatile int selected=-1; volatile boolean automatic=true;
 volatile String preferredSsid="",preferredSecurity="";
 volatile boolean bootPending; volatile long bootStart;
 JSONObject settings;
 WifiManager.MulticastLock multicast;
 F50WifiServer(File dir, boolean boot)throws Exception {
  directory=dir; if(!dir.isDirectory()&&!dir.mkdirs())throw new IOException("settings directory unavailable");
  Class<?> type=Class.forName("android.app.ActivityThread");
  Object thread=type.getMethod("systemMain").invoke(null);
  Context system=(Context)type.getMethod("getSystemContext").invoke(thread);
  context=system.createPackageContext("com.android.shell",0);
  // systemMain's package context retains opPackageName="android" on B28. Use
  // the real process owner (shell) for Wi-Fi AppOps and attribution checks.
  java.lang.reflect.Field op=context.getClass().getDeclaredField("mOpPackageName");op.setAccessible(true);op.set(context,"com.android.shell");
  java.lang.reflect.Field attribution=context.getClass().getDeclaredField("mAttributionSource");attribution.setAccessible(true);attribution.set(context,new android.content.AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build());
  wifi=context.getSystemService(WifiManager.class);
  File file=new File(dir,"settings.json");
  settings=file.isFile()?new JSONObject(read(file)):new JSONObject();
  automatic=settings.optBoolean("automatic",true);
  preferredSsid=settings.optString("preferred_ssid","");preferredSecurity=settings.optString("preferred_security","");
  // Android networkId is reassigned across reboot. Persist the profile identity.
  for(WifiConfiguration c:networks())if(unquote(c.SSID).equals(preferredSsid)&&security(c).equals(preferredSecurity))selected=c.networkId;
  bootPending=boot;bootStart=android.os.SystemClock.elapsedRealtime();
 }
 void persist()throws Exception {synchronized(storageLock){
  settings.remove("preferred_network");settings.put("automatic",automatic).put("preferred_ssid",preferredSsid).put("preferred_security",preferredSecurity);
  File temp=new File(directory,"settings.tmp");
  try(FileOutputStream output=new FileOutputStream(temp)){output.write(settings.toString().getBytes(StandardCharsets.UTF_8));output.getFD().sync();} if(!temp.renameTo(new File(directory,"settings.json")))throw new IOException("settings rename failed");
 }}
 static String read(File file)throws IOException {try(FileInputStream input=new FileInputStream(file)){return new String(input.readAllBytes(),StandardCharsets.UTF_8);}}
 static void write(File file,String value)throws IOException {try(FileOutputStream output=new FileOutputStream(file)){output.write(value.getBytes(StandardCharsets.UTF_8));output.getFD().sync();}}
 static String run(String...args)throws Exception {
  Process p=new ProcessBuilder(args).redirectErrorStream(true).start();
  CompletableFuture<byte[]> output=CompletableFuture.supplyAsync(()->{try{return p.getInputStream().readNBytes(32768);}catch(IOException e){return new byte[0];}});
  if(!p.waitFor(8,TimeUnit.SECONDS)){p.destroyForcibly();throw new IOException("command timeout");}
  return new String(output.get(2,TimeUnit.SECONDS),StandardCharsets.UTF_8).trim();
 }
 static String unquote(String s){if(s==null)return "";return s.startsWith("\"")&&s.endsWith("\"")?s.substring(1,s.length()-1):s;}
 List<WifiConfiguration> networks(){
  List<WifiConfiguration> n=wifi.getConfiguredNetworks();Map<Integer,WifiConfiguration> unique=new LinkedHashMap<>();
  // Android exposes PSK/SAE transition profiles twice with the same networkId.
  if(n!=null)for(WifiConfiguration c:n)if(!unique.containsKey(c.networkId)||c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_PSK))unique.put(c.networkId,c);
  return new ArrayList<>(unique.values());
 }
 String address(){try {NetworkInterface n=NetworkInterface.getByName("wlan0"); if(n!=null)for(InetAddress a:Collections.list(n.getInetAddresses()))if(a instanceof Inet4Address&&!a.isLinkLocalAddress())return a.getHostAddress();}catch(Exception ignored){}return "";}
 boolean hasRoute(){try{return run("ip","-4","route","show","table","wlan0").lines().anyMatch(line->line.startsWith("default "));}catch(Exception e){return false;}}
 boolean connected(){WifiInfo info=wifi.getConnectionInfo();return wifi.isWifiEnabled()&&info!=null&&info.getSupplicantState()==SupplicantState.COMPLETED&&info.getNetworkId()>=0&&!address().isEmpty()&&hasRoute();}
 String security(WifiConfiguration c){return c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.SAE)?"wpa3":c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_PSK)?"wpa2":c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_EAP)||c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.IEEE8021X)||Arrays.stream(c.wepKeys).anyMatch(Objects::nonNull)?"unsupported":"open";}
 JSONObject status()throws Exception {
  WifiInfo info=wifi.getConnectionInfo(); boolean ready=connected();
  JSONArray saved=new JSONArray();for(WifiConfiguration c:networks())saved.put(new JSONObject().put("id",c.networkId).put("ssid",unquote(c.SSID)).put("security",security(c)).put("preferred",c.networkId==selected).put("connected",ready&&info.getNetworkId()==c.networkId));
  String apName="F50 Pro 原热点";
  try {Object ap=wifi.getClass().getMethod("getSoftApConfiguration").invoke(wifi);String name=(String)ap.getClass().getMethod("getSsid").invoke(ap);if(name!=null)apName=name;}catch(Exception ignored){}
  return new JSONObject().put("mode",ready?"connected":mode).put("message",ready?"已连接，可通过此网络访问设备":message).put("error",lastError)
   .put("ssid",ready?unquote(info.getSSID()):"").put("ip",ready?address():"").put("automatic",automatic)
   .put("hotspot_ssid",apName).put("saved",saved).put("usb_adb",run("getprop","sys.usb.config").contains("adb"))
   .put("local_url","http://f50wifi.local:8088").put("setup_url","http://192.168.0.1:8088");
 }
 JSONArray scans()throws Exception {
  Map<String,JSONObject> found=new LinkedHashMap<>();
  for(ScanResult s:wifi.getScanResults()){
   if(s.SSID==null||s.SSID.isEmpty())continue;
   String type=s.capabilities.contains("PSK")?"wpa2":s.capabilities.contains("SAE")?"wpa3":s.capabilities.contains("EAP")||s.capabilities.contains("WEP")?"unsupported":"open";
   String key=s.SSID+"\0"+type;
   JSONObject old=found.get(key);if(old==null||s.level>old.optInt("signal"))found.put(key,new JSONObject().put("ssid",s.SSID).put("security",type).put("signal",s.level));
  }
  List<JSONObject> rows=new ArrayList<>(found.values());rows.sort((a,b)->Integer.compare(b.optInt("signal"),a.optInt("signal")));
  return new JSONArray(rows);
 }
 void tether(boolean start)throws Exception {
  Object manager=context.getSystemService("tethering");Class<?> type=Class.forName("android.net.TetheringManager");
  int kind=type.getField("TETHERING_WIFI").getInt(null);
  if(!start){type.getMethod("stopTethering",int.class).invoke(manager,kind);return;}
  Class<?> request=Class.forName("android.net.TetheringManager$TetheringRequest"),builder=Class.forName("android.net.TetheringManager$TetheringRequest$Builder"),callback=Class.forName("android.net.TetheringManager$StartTetheringCallback");
  Object spec=builder.getMethod("build").invoke(builder.getConstructor(int.class).newInstance(kind));
  CountDownLatch done=new CountDownLatch(1);boolean[] result={false};
  Object cb=Proxy.newProxyInstance(callback.getClassLoader(),new Class<?>[]{callback},(p,m,a)->{
   if(m.getName().equals("onTetheringStarted")){result[0]=true;done.countDown();}else if(m.getName().equals("onTetheringFailed"))done.countDown();return null;
  });
  type.getMethod("startTethering",request,Executor.class,callback).invoke(manager,spec,(Executor)Runnable::run,cb);
  if(!done.await(7,TimeUnit.SECONDS)||!result[0])throw new IOException("hotspot start failed");
 }
 void enableAll(){for(WifiConfiguration c:networks())wifi.enableNetwork(c.networkId,false);}
 int preferredId(){for(WifiConfiguration c:networks())if(unquote(c.SSID).equals(preferredSsid)&&security(c).equals(preferredSecurity))return c.networkId;return -1;}
 void prefer(int id)throws Exception {
  selected=-1;preferredSsid="";preferredSecurity="";
  for(WifiConfiguration c:networks())if(c.networkId==id){selected=id;preferredSsid=unquote(c.SSID);preferredSecurity=security(c);break;}
  persist();
 }
 void beginConnect(int id)throws Exception {
  bootPending=false;lastError="";prefer(id);id=selected;
  mode="connecting";message="正在连接，最多等待 90 秒；失败会恢复原热点";
  if(!new File("/dev/f50-ifconfig-ready").exists())throw new IOException("IP protection unavailable");
  if(!wifi.isWifiEnabled()){
   tether(false);
   for(int i=0;i<10&&run("getprop","init.svc.hostapd").equals("running");i++)Thread.sleep(500);
   Thread.sleep(2000);
   if(!wifi.setWifiEnabled(true))throw new IOException("Wi-Fi enable refused");
   for(int i=0;i<12&&!wifi.isWifiEnabled();i++)Thread.sleep(500);
  }
  // Keep the firmware's next boot in hotspot-first mode, as in the verified B28 patch.
  run("settings","put","global","wifi_on","0");
  enableAll();
  if(id>=0&&!wifi.enableNetwork(id,true))throw new IOException("saved network unavailable");
  wifi.reconnect();wifi.startScan();attemptStarted=android.os.SystemClock.elapsedRealtime();disconnectedAt=0;
 }
 void hotspot(String reason)throws Exception {
  bootPending=false;mode="recovering";message="正在恢复原热点";
  wifi.setWifiEnabled(false);run("settings","put","global","wifi_on","0");
  for(int i=0;i<12&&wifi.getWifiState()!=WifiManager.WIFI_STATE_DISABLED;i++)Thread.sleep(500);
  Thread.sleep(1000);tether(true);
  mode="hotspot";message="请连接设备原热点，在此添加或选择 Wi-Fi";lastError=reason;hotspotSince=android.os.SystemClock.elapsedRealtime();
 }
 static void reportFailure(Exception e){System.err.println("network_operation_failed="+e.getClass().getSimpleName());for(StackTraceElement frame:e.getStackTrace())if(frame.getClassName().startsWith("com.airsim.f50wifi"))System.err.println(frame);}
 void guarded(RunnableWithException action){control.schedule(()->{try{action.run();}catch(Exception e){reportFailure(e);lastError="网络操作未完成，请重试；USB 管理仍可用。";try{hotspot(lastError);}catch(Exception ignored){mode="error";message="热点恢复失败，请通过 USB 检查设备";}}},1500,TimeUnit.MILLISECONDS);}
 interface RunnableWithException{void run()throws Exception;}
 JSONObject action(String path,JSONObject in)throws Exception {
  switch(path){
   case "/api/scan": boolean accepted=wifi.startScan();return new JSONObject().put("accepted",accepted).put("networks",scans());
   case "/api/connect":{
    String ssid=in.optString("ssid"),security=in.optString("security"),password=in.optString("password");PortalRules.validate(ssid,security,password);
    WifiConfiguration config=new WifiConfiguration();config.SSID=PortalRules.quoted(ssid);config.hiddenSSID=in.optBoolean("hidden",false);
    for(WifiConfiguration existing:networks())if(unquote(existing.SSID).equals(ssid)&&security(existing).equals(security)){config.networkId=existing.networkId;break;}
    if(security.equals("wpa2")){config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK);config.preSharedKey=PortalRules.quoted(password);}
    else if(security.equals("wpa3")){config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.SAE);config.preSharedKey=PortalRules.quoted(password);}
    else config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
    int id=wifi.addNetwork(config);if(id<0)throw new IllegalArgumentException("保存失败，请核对网络名称和加密方式。");
    automatic=true;prefer(id);guarded(()->beginConnect(id));return new JSONObject().put("accepted",true);
   }
   case "/api/select":{int id=in.getInt("id");if(networks().stream().noneMatch(c->c.networkId==id&&!security(c).equals("unsupported")))throw new IllegalArgumentException("该网络已不存在，请刷新列表。");guarded(()->beginConnect(id));return new JSONObject().put("accepted",true);}
   case "/api/forget":{int id=in.getInt("id");WifiInfo current=wifi.getConnectionInfo();if(connected()&&current.getNetworkId()==id)throw new IllegalArgumentException("请先连接其他网络，再移除当前网络。");if(!wifi.removeNetwork(id))throw new IllegalArgumentException("没有移除该网络，请刷新后重试。");if(selected==id)prefer(-1);else persist();return new JSONObject().put("ok",true);}
   case "/api/automatic":automatic=in.getBoolean("enabled");persist();return new JSONObject().put("ok",true);
   case "/api/retry":guarded(()->beginConnect(-1));return new JSONObject().put("accepted",true);
   case "/api/hotspot":guarded(()->hotspot(""));return new JSONObject().put("accepted",true);
   default:throw new IllegalArgumentException("未知操作。");
  }
 }
 void tick(){try{
  long now=android.os.SystemClock.elapsedRealtime();
  if(bootPending){if(now<160000){message="开机准备中，稍后连接已保存网络";return;}bootPending=false;if(automatic&&!networks().isEmpty())beginConnect(preferredId());else hotspot("");return;}
  if(connected()){
   if(!mode.equals("connected")){run("settings","put","global","wifi_on","0");enableAll();lastError="";}
   mode="connected";message="已连接";disconnectedAt=0;return;
  }
  if(mode.equals("starting")){mode=wifi.isWifiEnabled()?"connecting":"hotspot";attemptStarted=now;hotspotSince=now;}
  if(mode.equals("connecting")){
   if(now-attemptStarted>90000){hotspot("未能连接。请核对密码、信号和网络认证要求。");return;}
   if((now-attemptStarted)/3000%5==0)wifi.startScan();
   if(now-attemptStarted>35000)enableAll(); // Another saved network may still work.
  }else if(mode.equals("connected")){
   if(disconnectedAt==0)disconnectedAt=now;
   if(now-disconnectedAt>20000)beginConnect(-1);
  }else if(mode.equals("hotspot")&&automatic&&!networks().isEmpty()&&now-hotspotSince>300000&&now-lastVisit>120000)beginConnect(-1);
 }catch(SecurityException e){reportFailure(e);mode="error";message="网络权限需要检查，已停止自动切换";}catch(Exception e){reportFailure(e);try{hotspot("自动连接未完成，已返回本地配置。");}catch(Exception ignored){mode="error";message="需要通过 USB 检查网络服务";}}}
 public static void main(String[] args)throws Exception {
  Thread.currentThread().setUncaughtExceptionHandler((thread,error)->{error.printStackTrace();System.exit(1);});
  if(args.length<1)throw new IllegalArgumentException("data directory required");
  Looper.prepareMainLooper();
  F50WifiServer server=new F50WifiServer(new File(args[0]),args.length>1&&args[1].equals("--boot"));
  PortalHttp http=new PortalHttp(server);http.start();
  server.multicast=server.wifi.createMulticastLock("F50WifiSetup");server.multicast.setReferenceCounted(false);server.multicast.acquire();
  new LocalName(server).start();server.control.scheduleWithFixedDelay(server::tick,1,3,TimeUnit.SECONDS);
  System.out.println("F50 Wi-Fi setup listening on local port 8088");Looper.loop();
 }
}
