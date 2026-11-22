package com.airsim.f50wifi;

import android.net.*;
import android.net.wifi.p2p.*;
import android.os.*;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.*;

/** Opt-in hotel sign-in over a temporary P2P group; no root, NAT or TLS interception. */
final class HotelLogin {
 static final long SESSION_MS=20*60*1000L;
 final F50WifiServer server;final WifiP2pManager manager;final ConnectivityManager connectivity;
 final Handler main=new Handler(Looper.getMainLooper());
 final ExecutorService checks=Executors.newSingleThreadExecutor();
 final String ssid,password;
 volatile String state="idle",message="需要网页登录的网络可在这里完成认证",address="",iface="",client="",pacToken="";
 volatile boolean online,checking;volatile long expires,checkedAt;volatile int generation;
 WifiP2pManager.Channel channel;HotelProxy proxy;Network uplink;String autoAttempt="";
 HotelLogin(F50WifiServer server)throws Exception {
  this.server=server;manager=server.context.getSystemService(WifiP2pManager.class);connectivity=server.context.getSystemService(ConnectivityManager.class);
  synchronized(server.storageLock){
   if(!server.settings.has("hotel_hotspot_password")){
    server.settings.put("hotel_hotspot_password",random(12)).put("hotel_hotspot_suffix",random(4).replace('-','A').replace('_','B'));server.persist();
   }
   password=server.settings.getString("hotel_hotspot_password");ssid="DIRECT-F5-F50-"+server.settings.getString("hotel_hotspot_suffix");
  }
 }
 static String random(int length){byte[] b=new byte[length];new SecureRandom().nextBytes(b);return Base64.getUrlEncoder().withoutPadding().encodeToString(b);}
 static long now(){return SystemClock.elapsedRealtime();}
 String key(String name,String security){return name+"\u0000"+security;}
 boolean enabled(String name,String security){synchronized(server.storageLock){return server.settings.optJSONObject("hotel_networks")!=null&&server.settings.optJSONObject("hotel_networks").optBoolean(key(name,security));}}
 void configure(String name,String security,boolean enabled)throws Exception {synchronized(server.storageLock){
  JSONObject profiles=server.settings.optJSONObject("hotel_networks");if(profiles==null)profiles=new JSONObject();
  if(enabled)profiles.put(key(name,security),true);else profiles.remove(key(name,security));server.settings.put("hotel_networks",profiles);server.persist();
  autoAttempt="";
 }}
 boolean active(){return state.equals("starting")||state.equals("ready");}
 boolean targetConnected(){return server.connected()&&server.wifi.getConnectionInfo().getNetworkId()==server.preferredId();}
 JSONObject status()throws JSONException {return new JSONObject().put("enabled",enabled(server.preferredSsid,server.preferredSecurity))
  .put("state",state).put("message",message).put("ssid",ssid).put("password",password).put("address",address)
  .put("setup_url","http://"+(address.isEmpty()?"192.168.49.1":address)+":8088")
  .put("pac_url",client.isEmpty()?"":"http://"+address+":8088/hotel/"+pacToken+".pac")
  .put("authorized",!client.isEmpty()).put("remaining_seconds",Math.max(0,(expires-now())/1000))
  .put("online",online&&targetConnected()).put("checking",checking).put("checked_at",checkedAt).put("available",manager!=null);}
 Network wifiNetwork(){for(Network n:connectivity.getAllNetworks()){
  NetworkCapabilities caps=connectivity.getNetworkCapabilities(n);LinkProperties links=connectivity.getLinkProperties(n);
  if(caps!=null&&caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)&&links!=null&&"wlan0".equals(links.getInterfaceName()))return n;
 }return null;}
 synchronized void start()throws Exception {
  server.callSafety.requireIdle();if(active())return;
  if(manager==null)throw new IllegalArgumentException("此设备没有临时认证热点接口。");
  if(!targetConnected())throw new IllegalArgumentException("请先保存酒店 Wi-Fi，勾选网页登录认证，再重启连接指定网络。");
  Network network=wifiNetwork();if(network==null)throw new IllegalArgumentException("Wi-Fi 路由尚未就绪，请稍后再试。");
  LinkProperties links=connectivity.getLinkProperties(network);
  for(LinkAddress link:links.getLinkAddresses())if(new IpPrefix(link.getAddress(),link.getPrefixLength()).contains(InetAddress.getByName("192.168.49.1")))throw new IllegalArgumentException("酒店地址与临时热点冲突，暂不能在此网络使用认证热点。");
  autoAttempt=server.bootId+key(server.preferredSsid,server.preferredSecurity);
  generation++;int epoch=generation;uplink=network;expires=now()+SESSION_MS;state="starting";message="正在开启临时认证热点";online=false;client="";pacToken=random(24);
  main.post(()->{try{
   channel=manager.initialize(server.context,Looper.getMainLooper(),()->fail(epoch,"临时热点接口断开，请重新开启。"));
   manager.requestGroupInfo(channel,existing->{
    if(epoch!=generation)return;
    if(existing!=null){if(ssid.equals(existing.getNetworkName())&&existing.isGroupOwner())pollGroup(epoch,0);else fail(epoch,"已有 Wi-Fi Direct 会话，请结束它后重试。");return;}
    WifiP2pConfig config=new WifiP2pConfig.Builder().setNetworkName(ssid).setPassphrase(password)
     .setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_2GHZ).enablePersistentMode(false).build();
    manager.createGroup(channel,config,new WifiP2pManager.ActionListener(){
     public void onSuccess(){pollGroup(epoch,0);}
     public void onFailure(int reason){fail(epoch,"临时热点未能开启（"+reason+"），原 Wi-Fi 保持不变。");}
    });
   });
  }catch(Exception e){fail(epoch,"临时热点权限不可用，请通过 USB 检查。");}});
 }
 void pollGroup(int epoch,int count){if(epoch!=generation)return;
  manager.requestGroupInfo(channel,group->{if(epoch!=generation)return;
   if(group==null||!group.isGroupOwner()){if(count<15)main.postDelayed(()->pollGroup(epoch,count+1),1000);else fail(epoch,"临时热点启动超时，请重试。");return;}
   try{
    iface=group.getInterface();NetworkInterface ni=NetworkInterface.getByName(iface);String ip="";
    if(ni!=null)for(InetAddress a:Collections.list(ni.getInetAddresses()))if(a instanceof Inet4Address)ip=a.getHostAddress();
    if(ip.isEmpty()){if(count<15)main.postDelayed(()->pollGroup(epoch,count+1),1000);else fail(epoch,"临时热点没有取得本地地址。");return;}
    synchronized(this){if(epoch!=generation)return;address=ip;proxy=new HotelProxy(InetAddress.getByName(ip),8089,this::authorized,this::connect);state="ready";message="请让 iPhone 加入认证热点，并在本页启用认证通道";}
   }catch(Exception e){fail(epoch,"临时认证通道启动失败，请重试。");}
  });
 }
 boolean onHotspot(InetAddress peer){try{
  NetworkInterface ni=NetworkInterface.getByName(iface);if(ni==null||!(peer instanceof Inet4Address))return false;
  for(InterfaceAddress a:ni.getInterfaceAddresses())if(a.getAddress() instanceof Inet4Address&&new IpPrefix(a.getAddress(),a.getNetworkPrefixLength()).contains(peer))return !peer.getHostAddress().equals(address);
 }catch(Exception ignored){}return false;}
 boolean authorized(InetAddress peer){return !client.isEmpty()&&state.equals("ready")&&now()<expires&&peer.getHostAddress().equals(client)&&onHotspot(peer);}
 synchronized void authorize(InetAddress peer){
  if(!state.equals("ready")||now()>=expires||!onHotspot(peer))throw new IllegalArgumentException("请先连接上方的临时热点，再用该热点地址登录本页。");
  if(!client.isEmpty()&&!client.equals(peer.getHostAddress()))throw new IllegalArgumentException("另一台设备正在认证，请先结束当前认证。");
  client=peer.getHostAddress();message="认证通道已开启，请按下方步骤设置 iPhone 代理";
 }
 String pac(String token,InetAddress peer){if(!authorized(peer)||!PortalRules.same(pacToken,token))return null;
  return "function FindProxyForURL(url,host){if(host==='"+address+"'||host==='192.168.0.1'||host==='f50wifi.local'||host==='localhost'||host==='127.0.0.1')return 'DIRECT';return 'PROXY "+address+":8089';}";
 }
 Socket connect(String host,int port)throws IOException {
  Network network=uplink;if(network==null||!network.equals(wifiNetwork())||now()>=expires)throw new IOException("Wi-Fi changed");
  Set<InetAddress> local=new HashSet<>();for(NetworkInterface ni:Collections.list(NetworkInterface.getNetworkInterfaces()))local.addAll(Collections.list(ni.getInetAddresses()));
  InetAddress[] destinations=network.getAllByName(host);IOException last=new IOException("destination unavailable");
  for(InetAddress destination:destinations){
   if(destination.isAnyLocalAddress()||destination.isLoopbackAddress()||destination.isLinkLocalAddress()||destination.isMulticastAddress()||local.contains(destination))continue;
   Socket socket=network.getSocketFactory().createSocket();try{socket.connect(new InetSocketAddress(destination,port),8000);return socket;}catch(IOException e){socket.close();last=e;}
  }throw last;
 }
 synchronized void check(boolean automatic){
  if(checking)return;if(!targetConnected())throw new IllegalArgumentException("尚未连接指定的酒店 Wi-Fi，请先保存并重启。");
  Network network=wifiNetwork();if(network==null){message="尚未连接酒店 Wi-Fi，请先保存并重启。";return;}
  checking=true;int epoch=generation;
  checks.execute(()->{boolean success=false;try{
   File pinned=new File(server.directory,"hotel-probe-url");String target=pinned.isFile()?F50WifiServer.read(pinned).trim():"https://connectivitycheck.gstatic.com/generate_204";
   URL url=new URL(target);if(!url.getProtocol().equals("https")||url.getUserInfo()!=null||url.getPort()!=-1&&url.getPort()!=443)throw new IOException("invalid check URL");
   HttpURLConnection connection=(HttpURLConnection)network.openConnection(url,java.net.Proxy.NO_PROXY);
   connection.setConnectTimeout(8000);connection.setReadTimeout(8000);connection.setInstanceFollowRedirects(false);
   try{int code=connection.getResponseCode();if(pinned.isFile()){
    if(code==200){String body=new String(connection.getInputStream().readNBytes(8192),StandardCharsets.UTF_8);JSONObject result=new JSONObject(body);success=result.optBoolean("ok")&&result.optString("service").equals("airsim-push-relay");}
   }else success=code==204;}finally{connection.disconnect();}
  }catch(Exception ignored){}finally{
   synchronized(this){checking=false;if(epoch!=generation||!network.equals(wifiNetwork()))return;online=success;checkedAt=System.currentTimeMillis();
    message=success?"F50 已通过 HTTPS 联网检查，可结束认证并关闭临时热点":"F50 尚未通过联网检查，请完成酒店登录后重试";
    if(automatic&&!success){try{start();}catch(CallSafeNetworkPolicy.Deferred busy){autoAttempt="";message=busy.getMessage();}catch(Exception e){state="error";message=e.getMessage();}}
   }
  }});
 }
 synchronized void stop(String reason){
  generation++;if(proxy!=null){proxy.close();proxy=null;}client="";pacToken="";address="";iface="";expires=0;uplink=null;
  WifiP2pManager.Channel previous=channel;channel=null;state="idle";message=reason;
  if(previous!=null)main.post(()->{try{manager.requestGroupInfo(previous,g->{
   if(g!=null&&ssid.equals(g.getNetworkName()))manager.removeGroup(previous,new WifiP2pManager.ActionListener(){public void onSuccess(){previous.close();}public void onFailure(int r){previous.close();}});
   else previous.close();
  });}catch(Exception ignored){previous.close();}});
 }
 synchronized void fail(int epoch,String reason){if(epoch!=generation)return;stop(reason);state="error";}
 synchronized void tick(){
  if(active()){
   if(now()>=expires){stop("认证窗口已到期，临时热点已关闭；可重新开启");return;}
   if(!targetConnected()||uplink==null||!uplink.equals(wifiNetwork())){stop("酒店 Wi-Fi 已断开，认证通道已关闭");return;}
  }
  String attempt=server.bootId+key(server.preferredSsid,server.preferredSecurity);
  if(!active()&&!checking&&targetConnected()&&enabled(server.preferredSsid,server.preferredSecurity)&&!attempt.equals(autoAttempt)){
   if(!server.callSafety.sample())return;
   autoAttempt=attempt;check(true);
  }
 }
}
