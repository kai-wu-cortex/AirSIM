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

/** MU3356-specific local Wi-Fi setup. Runs as shell; optional SIM supervision is separately owner-enabled. */
public final class F50WifiServer {
 final Context context; final WifiManager wifi; final File directory;
 final ScheduledExecutorService control=Executors.newSingleThreadScheduledExecutor();
 final Object storageLock=new Object();
 volatile String mode="starting",message="正在准备网络服务",lastError="";
 volatile long attemptStarted=0,disconnectedAt=0;
 volatile int selected=-1; volatile boolean automatic=true;
 volatile String preferredSsid="",preferredSecurity="",setupBootId="";
 final String bootId;
 volatile boolean bootPending; boolean operationPending,bootHotspotReady;
 JSONObject settings;
 WifiManager.MulticastLock multicast;
 final AirSimSupervisor airSim;
 final DualSimSupervisor dualSim;
 String lastBootReadiness="";
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
  bootId=read(new File("/proc/sys/kernel/random/boot_id")).trim();setupBootId=settings.optString("setup_boot_id","");
  // Android networkId is reassigned across reboot. Persist the profile identity.
  for(WifiConfiguration c:networks())if(unquote(c.SSID).equals(preferredSsid)&&security(c).equals(preferredSecurity))selected=c.networkId;
  bootPending=boot&&!setupBootId.equals(bootId)&&!connected();
  airSim=new AirSimSupervisor(this);dualSim=new DualSimSupervisor(this);
 }
 void persist()throws Exception {synchronized(storageLock){
  settings.remove("preferred_network");settings.put("automatic",automatic).put("preferred_ssid",preferredSsid).put("preferred_security",preferredSecurity).put("setup_boot_id",setupBootId);
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
 String usbHostState(){try{File[] controllers=new File("/sys/class/udc").listFiles();if(controllers!=null&&controllers.length>0)return read(new File(controllers[0],"state")).trim();}catch(Exception ignored){}return "unknown";}
 String security(WifiConfiguration c){return c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.SAE)?"wpa3":c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_PSK)?"wpa2":c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.WPA_EAP)||c.allowedKeyManagement.get(WifiConfiguration.KeyMgmt.IEEE8021X)||Arrays.stream(c.wepKeys).anyMatch(Objects::nonNull)?"unsupported":"open";}
 JSONObject status()throws Exception {
  WifiInfo info=wifi.getConnectionInfo(); boolean ready=connected();
  JSONArray saved=new JSONArray();for(WifiConfiguration c:networks())saved.put(new JSONObject().put("id",c.networkId).put("ssid",unquote(c.SSID)).put("security",security(c)).put("preferred",c.networkId==selected).put("connected",ready&&info.getNetworkId()==c.networkId));
  String apName="F50 Pro 原热点";
  try {Object ap=wifi.getClass().getMethod("getSoftApConfiguration").invoke(wifi);String name=(String)ap.getClass().getMethod("getSsid").invoke(ap);if(name!=null)apName=name;}catch(Exception ignored){}
  return new JSONObject().put("mode",mode.equals("rebooting")?mode:ready?"connected":mode).put("message",mode.equals("rebooting")?message:ready?"已连接，可通过此网络访问设备":message).put("error",lastError)
   .put("ssid",ready?unquote(info.getSSID()):"").put("ip",ready?address():"").put("automatic",automatic)
   .put("target_ssid",preferredSsid).put("can_reboot",preferredId()>=0)
   .put("uptime_seconds",android.os.SystemClock.elapsedRealtime()/1000).put("usb_host_state",usbHostState()).put("airsim_bridge",airSim.status()).put("dual_sim",dualSim.status())
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
 void onlyTarget(int id)throws Exception {
  for(WifiConfiguration c:networks())if(c.networkId!=id&&!wifi.disableNetwork(c.networkId))throw new IOException("other profile disable failed");
 }
 int preferredId(){for(WifiConfiguration c:networks())if(unquote(c.SSID).equals(preferredSsid)&&security(c).equals(preferredSecurity))return c.networkId;return -1;}
 void prefer(int id)throws Exception {
  selected=-1;preferredSsid="";preferredSecurity="";
  for(WifiConfiguration c:networks())if(c.networkId==id){selected=id;preferredSsid=unquote(c.SSID);preferredSecurity=security(c);break;}
  persist();
 }
 void beginConnect(int id)throws Exception {
  if(id<0)throw new IllegalArgumentException("请先指定要连接的 Wi-Fi，再重启设备。");
  bootPending=false;lastError="";selected=id;
  mode="connecting";message="正在连接，最多等待 90 秒；失败会恢复原热点";
  if(!new File("/dev/f50-ifconfig-ready").exists())throw new IOException("IP protection unavailable");
  // Disable alternatives before enabling STA: a saved home network must never
  // hide a failed travel-network setup by taking over automatically.
  onlyTarget(id);
  if(!wifi.isWifiEnabled()){
   tether(false);
   for(int i=0;i<10&&run("getprop","init.svc.hostapd").equals("running");i++)Thread.sleep(500);
   Thread.sleep(2000);
   if(!wifi.setWifiEnabled(true))throw new IOException("Wi-Fi enable refused");
   for(int i=0;i<12&&!wifi.isWifiEnabled();i++)Thread.sleep(500);
  }
  // Keep the firmware's next boot in hotspot-first mode, as in the verified B28 patch.
  run("settings","put","global","wifi_on","0");
  if(id>=0&&!wifi.enableNetwork(id,true))throw new IOException("saved network unavailable");
  wifi.reconnect();wifi.startScan();attemptStarted=android.os.SystemClock.elapsedRealtime();disconnectedAt=0;
 }
 void hotspot(String reason)throws Exception {
  bootPending=false;setupBootId=bootId;persist();mode="recovering";message="正在恢复原热点";
  wifi.setWifiEnabled(false);run("settings","put","global","wifi_on","0");
  for(int i=0;i<12&&wifi.getWifiState()!=WifiManager.WIFI_STATE_DISABLED;i++)Thread.sleep(500);
  Thread.sleep(1000);
  // init can restart this service while the AP is already active. B28 reports
  // a failed callback for a duplicate start, although the existing AP is fine.
  if(!run("getprop","init.svc.hostapd").equals("running"))tether(true);
  mode="hotspot";message="请填写目标 Wi-Fi；保存后保持热点，重启后才切换连接";lastError=reason;
 }
 void stage(int id)throws Exception {automatic=true;bootPending=false;setupBootId=bootId;prefer(id);lastError="";}
 synchronized void openedSetup()throws Exception {
  // An authenticated person using the boot-time AP owns this setup session.
  // Do not interrupt their form when the normal boot delay expires.
  if(bootPending&&!wifi.isWifiEnabled()&&run("getprop","init.svc.hostapd").equals("running")){
   setupBootId=bootId;persist();bootPending=false;mode="hotspot";
   message="配网热点已保留，请填写目标 Wi-Fi，准备好后保存并重启";
  }
 }
 void requestReboot()throws Exception {
  if(preferredId()<0)throw new IllegalArgumentException("请先保存或指定一个 Wi-Fi。");
  if(context.checkSelfPermission("android.permission.REBOOT")!=android.content.pm.PackageManager.PERMISSION_GRANTED)throw new IllegalArgumentException("当前设备不允许页面重启，请手动重启。");
  run("settings","put","global","wifi_on","0");
  automatic=true;bootPending=false;persist();mode="rebooting";message="设备即将重启，系统启动满 1 分钟且就绪后开始连接 Wi-Fi";
  guarded(()->context.getSystemService(android.os.PowerManager.class).reboot(null));
 }
 static void reportFailure(Exception e){System.err.println("network_operation_failed="+e.getClass().getSimpleName());for(StackTraceElement frame:e.getStackTrace())if(frame.getClassName().startsWith("com.airsim.f50wifi"))System.err.println(frame);}
 void guarded(RunnableWithException action){operationPending=true;control.schedule(()->{synchronized(this){try{action.run();}catch(Exception e){reportFailure(e);lastError="网络操作未完成，请重试；USB 管理仍可用。";try{hotspot(lastError);}catch(Exception ignored){mode="error";message="热点恢复失败，请通过 USB 检查设备";}}finally{operationPending=false;}}},1500,TimeUnit.MILLISECONDS);}
 interface RunnableWithException{void run()throws Exception;}
 synchronized JSONObject action(String path,JSONObject in)throws Exception {
  if(operationPending||mode.equals("rebooting")||mode.equals("recovering")||mode.equals("connecting"))throw new IllegalArgumentException("设备正在切换，请等待完成后再操作。");
  switch(path){
   case "/api/scan": boolean accepted=wifi.isWifiEnabled()&&wifi.startScan();return new JSONObject().put("accepted",accepted).put("networks",wifi.isWifiEnabled()?scans():new JSONArray());
   case "/api/save":{
    String ssid=in.optString("ssid"),security=in.optString("security"),password=in.optString("password");PortalRules.validate(ssid,security,password);
    WifiConfiguration config=new WifiConfiguration();config.SSID=PortalRules.quoted(ssid);config.hiddenSSID=in.optBoolean("hidden",false);
    for(WifiConfiguration existing:networks())if(unquote(existing.SSID).equals(ssid)&&security(existing).equals(security)){config.networkId=existing.networkId;break;}
    if(security.equals("wpa2")){config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK);config.preSharedKey=PortalRules.quoted(password);}
    else if(security.equals("wpa3")){config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.SAE);config.preSharedKey=PortalRules.quoted(password);}
    else config.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
    int id=wifi.addNetwork(config);if(id<0)throw new IllegalArgumentException("保存失败，请核对网络名称和加密方式。");
    stage(id);if(in.optBoolean("reboot",false))requestReboot();return new JSONObject().put("saved",true).put("rebooting",in.optBoolean("reboot",false));
   }
   case "/api/select":{int id=in.getInt("id");if(networks().stream().noneMatch(c->c.networkId==id&&!security(c).equals("unsupported")))throw new IllegalArgumentException("该网络已不存在，请刷新列表。");stage(id);return new JSONObject().put("saved",true);}
   case "/api/forget":{int id=in.getInt("id");WifiInfo current=wifi.getConnectionInfo();if(connected()&&current.getNetworkId()==id)throw new IllegalArgumentException("请先连接其他网络，再移除当前网络。");if(!wifi.removeNetwork(id))throw new IllegalArgumentException("没有移除该网络，请刷新后重试。");if(selected==id)prefer(-1);else persist();return new JSONObject().put("ok",true);}
   case "/api/automatic":automatic=in.getBoolean("enabled");persist();return new JSONObject().put("ok",true);
   case "/api/reboot":requestReboot();return new JSONObject().put("accepted",true);
   case "/api/connect":case "/api/retry":throw new IllegalArgumentException("配网流程已更新，请刷新页面后保存并重启。");
   case "/api/hotspot":guarded(()->hotspot(""));return new JSONObject().put("accepted",true);
   default:throw new IllegalArgumentException("未知操作。");
  }
 }
 synchronized void tick(){try{
  long now=android.os.SystemClock.elapsedRealtime();
  if(operationPending||mode.equals("rebooting"))return;
  if(bootPending){
   boolean systemReady=run("getprop","sys.boot_completed").equals("1"),guardReady=new File("/dev/f50-ifconfig-ready").exists();
   // The verified guard is installed after system boot, independently of USB.
   // A connected USB host is not a prerequisite for Wi-Fi or AirSIM.
   boolean ready=systemReady&&guardReady;
   String readiness="system="+systemReady+" guard="+guardReady+" usb="+run("getprop","sys.usb.state")+" host="+usbHostState();
   if(!readiness.equals(lastBootReadiness)){System.out.println("boot_readiness uptime="+(now/1000)+" "+readiness);lastBootReadiness=readiness;}
   if(!ready){if(now<180000){message="等待设备完成启动，准备好后自动连接 Wi-Fi";return;}hotspot("启动准备尚未完成，已保留热点；请稍后重启重试。");return;}
   // Stock B28 may remember that tethering was stopped before a STA reboot.
   // Explicitly offer the setup AP before the one-minute transition. Do not
   // disturb a STA attempt when init merely restarts this process mid-connect.
   if(!bootHotspotReady){if(!wifi.isWifiEnabled()&&!run("getprop","init.svc.hostapd").equals("running"))tether(true);bootHotspotReady=true;}
   if(now<60000){message="开机准备中，系统启动满 1 分钟后尝试指定 Wi-Fi";return;}
   if(automatic&&preferredId()>=0){
    beginConnect(preferredId());
   }else hotspot("");
   return;
  }
  if(connected()){
   if(!mode.equals("connected")){run("settings","put","global","wifi_on","0");lastError="";}
   mode="connected";message="已连接";disconnectedAt=0;return;
  }
  if(mode.equals("starting")){if(!wifi.isWifiEnabled()){hotspot("");return;}mode="connecting";attemptStarted=now;}
  if(mode.equals("connecting")){
   if(now-attemptStarted>90000){hotspot("未能连接。请核对密码、信号和网络认证要求。");return;}
   if((now-attemptStarted)/3000%5==0)wifi.startScan();
  }else if(mode.equals("connected")){
   if(disconnectedAt==0)disconnectedAt=now;
   if(now-disconnectedAt>20000)beginConnect(preferredId());
  }
 }catch(SecurityException e){reportFailure(e);mode="error";message="网络权限需要检查，已停止自动切换";}catch(Exception e){reportFailure(e);try{hotspot("自动连接未完成，已返回本地配置。");}catch(Exception ignored){mode="error";message="需要通过 USB 检查网络服务";}}}
 public static void main(String[] args)throws Exception {
  Thread.currentThread().setUncaughtExceptionHandler((thread,error)->{error.printStackTrace();System.exit(1);});
  if(args.length<1)throw new IllegalArgumentException("data directory required");
  Looper.prepareMainLooper();
  F50WifiServer server=new F50WifiServer(new File(args[0]),args.length>1&&args[1].equals("--boot"));
  PortalHttp http=new PortalHttp(server);http.start();
  server.airSim.start();server.dualSim.start();
  server.multicast=server.wifi.createMulticastLock("F50WifiSetup");server.multicast.setReferenceCounted(false);server.multicast.acquire();
  new LocalName(server).start();server.control.scheduleWithFixedDelay(server::tick,1,3,TimeUnit.SECONDS);
  System.out.println("F50 Wi-Fi setup listening on local port 8088");Looper.loop();
 }
}
