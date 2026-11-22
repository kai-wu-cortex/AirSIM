package com.airsim.f50wifi;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

public final class HotelProxyTest {
 static void check(boolean value){if(!value)throw new AssertionError();}
 static HotelProxy.Request parse(String text)throws IOException{return HotelProxy.parse(new ByteArrayInputStream(text.getBytes(StandardCharsets.ISO_8859_1)));}
 static void reject(String text)throws IOException{try{parse(text);throw new AssertionError("accepted invalid request");}catch(IOException expected){}}
 public static void main(String[] args)throws Exception{
  HotelProxy.Request r=parse("POST http://login.hotel.test/accept?room=sample HTTP/1.1\r\nHost: login.hotel.test\r\nContent-Length: 4\r\nCookie: session=sample\r\nProxy-Authorization: Basic not-forwarded\r\n\r\n");
  check(r.port==80&&r.firstLine.equals("POST /accept?room=sample HTTP/1.1"));
  check(r.headers.contains("Cookie: session=sample")&&r.headers.stream().noneMatch(s->s.startsWith("Proxy-Authorization")));
  reject("CONNECT example.test:22 HTTP/1.1\r\n\r\n");
  reject("GET http://a.test/ HTTP/1.1\r\nHost: b.test\r\n\r\n");
  reject("POST http://a.test/ HTTP/1.1\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n");
  reject("POST http://a.test/ HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n");
  reject("GET http://user:password@a.test/ HTTP/1.1\r\n\r\n");
  reject("GET http://localhost/ HTTP/1.1\r\n\r\n");
  reject("GET http://a.test/ HTTP/1.1\n\n");
  reject("CONNECT a.test:443 HTTP/1.1\r\nContent-Length: 1\r\n\r\n");
  InetAddress loop=InetAddress.getLoopbackAddress();AtomicBoolean allowed=new AtomicBoolean(false);
  try(ServerSocket echo=new ServerSocket(0,4,loop);HotelProxy proxy=new HotelProxy(loop,0,peer->allowed.get(),(host,port)->{
   check(host.equals("hotel.test")&&port==443);return new Socket(loop,echo.getLocalPort());
  })){
   try(Socket denied=new Socket(loop,proxy.port())){denied.setSoTimeout(2000);check(denied.getInputStream().read()==-1);}
   allowed.set(true);
   ExecutorService worker=Executors.newSingleThreadExecutor();
   Future<?> server=worker.submit(()->{try(Socket peer=echo.accept()){
    byte[] payload=peer.getInputStream().readNBytes(5);check(payload.length==5&&payload[0]==0&&payload[4]==(byte)255);
    peer.getOutputStream().write(payload);peer.getOutputStream().flush();
   }catch(IOException e){throw new RuntimeException(e);}});
   try(Socket phone=new Socket(loop,proxy.port())){phone.setSoTimeout(3000);
    phone.getOutputStream().write("CONNECT hotel.test:443 HTTP/1.1\r\nHost: hotel.test:443\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
    check(HotelProxy.line(phone.getInputStream(),128).contains("200"));check(HotelProxy.line(phone.getInputStream(),128).isEmpty());
    byte[] opaque={0,1,2,3,(byte)255};phone.getOutputStream().write(opaque);phone.getOutputStream().flush();
    check(java.util.Arrays.equals(opaque,phone.getInputStream().readNBytes(5)));
   }
   server.get(3,TimeUnit.SECONDS);worker.shutdownNow();
  }
  System.out.println("HotelProxyTest passed: framing, target validation, denied client and opaque CONNECT roundtrip");
 }
}
