package com.airsim.f50wifi;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
public final class PortalRules {
 public static final int MAX_BODY=8192, MAX_HEADERS=12288;
 public static boolean local(InetAddress address){return address.isLoopbackAddress()||address.isSiteLocalAddress()||address.isLinkLocalAddress();}
 public static boolean same(String a,String b){return a!=null&&b!=null&&MessageDigest.isEqual(a.getBytes(StandardCharsets.UTF_8),b.getBytes(StandardCharsets.UTF_8));}
 // WifiConfiguration/NativeUtil strips only the enclosing quotes. No shell
 // escaping: adding backslashes would change the actual SSID or password.
 public static String quoted(String v){return "\""+v+"\"";}
 public static void validate(String ssid,String security,String password){
  int n=ssid.getBytes(StandardCharsets.UTF_8).length;
  if(n<1||n>32||ssid.indexOf('\0')>=0||ssid.indexOf('\n')>=0||ssid.indexOf('\r')>=0)throw new IllegalArgumentException("Wi-Fi 名称需为 1–32 字节，且不能包含换行。");
  if(!security.equals("open")&&!security.equals("wpa2")&&!security.equals("wpa3"))throw new IllegalArgumentException("暂不支持这种加密方式，请选择 WPA2、WPA3 或开放网络。");
  if(!security.equals("open")&&(password.length()<8||password.length()>63||password.indexOf('\0')>=0||password.indexOf('\n')>=0||password.indexOf('\r')>=0))throw new IllegalArgumentException("Wi-Fi 密码需为 8–63 个字符。");
 }
 public static boolean validOrigin(String origin,String host){return origin!=null&&host!=null&&origin.equals("http://"+host);}
 public static boolean validHost(String host){
  if(host==null||!host.endsWith(":8088"))return false;
  String h=host.substring(0,host.length()-5).toLowerCase(Locale.ROOT);
  if(h.equals("f50wifi.local")||h.equals("localhost")||h.equals("127.0.0.1"))return true;
  if(!h.matches("[0-9.]+"))return false;
  try{return local(InetAddress.getByName(h));}catch(Exception e){return false;}
 }
}
