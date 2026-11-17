package com.airsim.f50wifi;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
/** Minimal link-local A responder for the local setup hostname, no forwarding or cloud DNS. */
final class LocalName extends Thread {
 final F50WifiServer server;
 LocalName(F50WifiServer s){super("f50-wifi-mdns");server=s;setDaemon(true);}
 static void name(DataOutputStream out,String name)throws IOException {for(String label:name.split("\\.")){byte[] b=label.getBytes(StandardCharsets.US_ASCII);out.writeByte(b.length);out.write(b);}out.writeByte(0);}
 static boolean question(byte[] b,int size){
  if(size<12||(b[2]&128)!=0)return false;int p=12;
  int count=((b[4]&255)<<8)|(b[5]&255);
  for(int q=0;q<count&&q<20;q++){StringBuilder n=new StringBuilder();int labels=0;
   while(p<size){int length=b[p++]&255;if(length==0)break;if(length>63||p+length>size||++labels>10)return false;if(n.length()>0)n.append('.');n.append(new String(b,p,length,StandardCharsets.US_ASCII));p+=length;}
   if(p+4>size)return false;int type=((b[p]&255)<<8)|(b[p+1]&255);p+=4;if(n.toString().equalsIgnoreCase("f50wifi.local")&&(type==1||type==255))return true;
  }return false;
 }
 static List<NetworkInterface> interfaces(){List<NetworkInterface> out=new ArrayList<>();try{for(NetworkInterface n:Collections.list(NetworkInterface.getNetworkInterfaces()))if(n.isUp()&&!n.isLoopback()&&(n.getName().equals("wlan0")||n.getName().equals("br0")||n.getName().startsWith("usb")||n.getName().startsWith("rndis")))out.add(n);}catch(Exception ignored){}return out;}
 public void run(){while(true)try(MulticastSocket socket=new MulticastSocket(null)){
  socket.setReuseAddress(true);socket.bind(new InetSocketAddress(5353));socket.setTimeToLive(255);socket.setSoTimeout(5000);
  Set<String> joined=new HashSet<>();
  while(true){for(NetworkInterface n:interfaces())if(!joined.contains(n.getName()+":"+n.getIndex()))try{socket.joinGroup(new InetSocketAddress("224.0.0.251",5353),n);joined.add(n.getName()+":"+n.getIndex());}catch(Exception ignored){}
   byte[] b=new byte[1500];DatagramPacket packet=new DatagramPacket(b,b.length);try{socket.receive(packet);}catch(SocketTimeoutException e){continue;}
   if(!PortalRules.local(packet.getAddress())||!question(b,packet.getLength()))continue;
   for(NetworkInterface n:interfaces())for(InterfaceAddress ia:n.getInterfaceAddresses()){
    InetAddress a=ia.getAddress();if(!(a instanceof Inet4Address))continue;
    byte[] peer=packet.getAddress().getAddress(),local=a.getAddress();if(peer.length!=4)continue;
    int bits=ia.getNetworkPrefixLength(),ip=0,other=0;for(int i=0;i<4;i++){ip=(ip<<8)|(local[i]&255);other=(other<<8)|(peer[i]&255);}int mask=bits==0?0:-1<<(32-bits);if((ip&mask)!=(other&mask))continue;
    ByteArrayOutputStream bytes=new ByteArrayOutputStream();DataOutputStream out=new DataOutputStream(bytes);
    out.writeShort(packet.getPort()==5353?0:((b[0]&255)<<8)|(b[1]&255));out.writeShort(0x8400);out.writeShort(0);out.writeShort(1);out.writeShort(0);out.writeShort(0);
    name(out,"f50wifi.local");out.writeShort(1);out.writeShort(0x8001);out.writeInt(30);out.writeShort(4);out.write(local);
    socket.setNetworkInterface(n);byte[] answer=bytes.toByteArray();socket.send(new DatagramPacket(answer,answer.length,packet.getPort()==5353?InetAddress.getByName("224.0.0.251"):packet.getAddress(),packet.getPort()));
   }
  }
 }catch(Exception ignored){try{Thread.sleep(5000);}catch(InterruptedException stop){return;}}}
}
