package com.airsim.f50wifi;
import java.net.InetAddress;
public class PortalRulesTest {
 static void check(boolean v){if(!v)throw new AssertionError();}
 static void invalid(String s,String type,String p){try{PortalRules.validate(s,type,p);throw new AssertionError();}catch(IllegalArgumentException expected){}}
 public static void main(String[] args)throws Exception{
  PortalRules.validate("家里的 Wi-Fi","wpa2","abc12345");
  PortalRules.validate("a\";$(not-a-command)","wpa2","abc12345");
  PortalRules.validate("Guest","open","");
  invalid("","open",""); invalid("a\nb","open",""); invalid("家".repeat(11),"open","");invalid("a","eap","abc12345");invalid("a","wpa2","short");
  String literal="a\"\\b;$(literal)";String wrapped=PortalRules.quoted(literal);
  check(wrapped.charAt(0)=='"'&&wrapped.charAt(wrapped.length()-1)=='"');
  check(wrapped.substring(1,wrapped.length()-1).equals(literal));
  check(PortalRules.same("a","a")&&!PortalRules.same("a","b"));
  check(PortalRules.validHost("f50wifi.local:8088"));check(PortalRules.validHost("192.168.0.1:8088"));
  check(!PortalRules.validHost("evil.example:8088"));check(!PortalRules.validHost("8.8.8.8:8088"));
  check(PortalRules.validOrigin("http://f50wifi.local:8088","f50wifi.local:8088"));
  check(!PortalRules.validOrigin("https://evil.example","f50wifi.local:8088"));
  check(!PortalRules.local(InetAddress.getByName("8.8.8.8")));
  System.out.println("PortalRulesTest passed");
 }
}
