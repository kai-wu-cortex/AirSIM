package com.airsim.f50wifi;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Predicate;

/** Short-lived, single-client HTTP/CONNECT proxy. TLS stays between Safari and the hotel. */
final class HotelProxy implements AutoCloseable {
 interface Dialer { Socket connect(String host,int port)throws IOException; }
 final ServerSocket listener=new ServerSocket();
 final Set<Socket> sockets=ConcurrentHashMap.newKeySet();
 final ExecutorService workers=new ThreadPoolExecutor(0,24,20,TimeUnit.SECONDS,new SynchronousQueue<>());
 final Predicate<InetAddress> authorized; final Dialer dialer;
 volatile boolean closed;
 final java.util.concurrent.atomic.AtomicInteger requests=new java.util.concurrent.atomic.AtomicInteger();
 final java.util.concurrent.atomic.AtomicInteger failures=new java.util.concurrent.atomic.AtomicInteger();
 HotelProxy(InetAddress address,int port,Predicate<InetAddress> allowed,Dialer dialer)throws IOException {
  authorized=allowed;this.dialer=dialer;listener.setReuseAddress(true);listener.bind(new InetSocketAddress(address,port),8);
  Thread thread=new Thread(()->{while(!closed)try{
   Socket client=listener.accept();
   if(!authorized.test(client.getInetAddress())){client.close();continue;}
   sockets.add(client);try{workers.execute(()->serve(client));}catch(RejectedExecutionException e){sockets.remove(client);client.close();}
  }catch(IOException ignored){}},"hotel-proxy");thread.setDaemon(true);thread.start();
 }
 int port(){return listener.getLocalPort();}
 static final class Request {
  final String host,firstLine;final int port;final boolean tunnel;final List<String> headers;
  Request(String host,int port,boolean tunnel,String line,List<String> headers){this.host=host;this.port=port;this.tunnel=tunnel;firstLine=line;this.headers=headers;}
 }
 static String line(InputStream input,int max)throws IOException {
  ByteArrayOutputStream out=new ByteArrayOutputStream();
  for(int i=0;i<max;i++){int c=input.read();if(c<0)throw new EOFException();if(c=='\n'){
   byte[] b=out.toByteArray();if(b.length==0||b[b.length-1]!='\r')throw new IOException("CRLF required");
   return new String(b,0,b.length-1,StandardCharsets.ISO_8859_1);
  }if(c==0||c<32&&c!='\r'&&c!='\t')throw new IOException("invalid header");out.write(c);}
  throw new IOException("header too long");
 }
 static Request parse(InputStream input)throws IOException {
  String[] start=line(input,4096).split(" ",-1);
  if(start.length!=3||!start[2].equals("HTTP/1.1"))throw new IOException("HTTP/1.1 required");
  boolean tunnel=start[0].equals("CONNECT");String host,requestPath="";int port;
  try {
   if(tunnel){
    if(!start[1].matches("[A-Za-z0-9.-]+:443"))throw new IOException("HTTPS destination required");
    host=start[1].substring(0,start[1].length()-4);port=443;
   }else{
    if(!Set.of("GET","HEAD","POST","OPTIONS").contains(start[0]))throw new IOException("unsupported method");
    URI uri=new URI(start[1]);host=uri.getHost();port=uri.getPort()<0?80:uri.getPort();
    if(!"http".equals(uri.getScheme())||host==null||uri.getRawUserInfo()!=null||uri.getRawFragment()!=null||port!=80)throw new IOException("HTTP destination required");
    requestPath=uri.getRawPath();if(requestPath.isEmpty())requestPath="/";if(uri.getRawQuery()!=null)requestPath+="?"+uri.getRawQuery();
   }
   if(host.length()>253||!host.matches("[A-Za-z0-9.-]+")||host.equalsIgnoreCase("localhost")||host.endsWith(".localhost"))throw new IOException("invalid host");
  }catch(URISyntaxException e){throw new IOException("invalid target");}
  List<String> headers=new ArrayList<>();Set<String> names=new HashSet<>();int size=0;String length=null,encoding=null;
  while(true){String header=line(input,4096);size+=header.length();if(size>16384)throw new IOException("headers too large");if(header.isEmpty())break;
   int at=header.indexOf(':');if(at<1||!header.substring(0,at).matches("[A-Za-z0-9-]+"))throw new IOException("invalid header");
   String name=header.substring(0,at).toLowerCase(Locale.ROOT),value=header.substring(at+1).trim();
   if(Set.of("host","content-length","transfer-encoding","connection").contains(name)&&!names.add(name))throw new IOException("duplicate header");
   if(name.equals("host")&&!value.equalsIgnoreCase(host)&&!value.equalsIgnoreCase(host+":"+port))throw new IOException("host mismatch");
   if(name.equals("content-length")){length=value;try{if(!value.matches("[0-9]+")||Long.parseLong(value)>1048576)throw new IOException("body too large");}catch(NumberFormatException e){throw new IOException("invalid length");}}
   if(name.equals("transfer-encoding")){encoding=value;if(!value.equalsIgnoreCase("chunked"))throw new IOException("unsupported encoding");}
   if(!Set.of("proxy-authorization","proxy-connection","connection","host").contains(name))headers.add(header);
  }
  if(length!=null&&encoding!=null)throw new IOException("ambiguous framing");
  if(tunnel&&(encoding!=null||length!=null&&!length.equals("0")))throw new IOException("CONNECT body not allowed");
  headers.add("Host: "+host+(tunnel?":443":""));headers.add("Connection: close");
  return new Request(host,port,tunnel,start[0]+" "+requestPath+" HTTP/1.1",headers);
 }
 static void write(Socket socket,String value)throws IOException {socket.getOutputStream().write(value.getBytes(StandardCharsets.ISO_8859_1));socket.getOutputStream().flush();}
 void serve(Socket client){Socket upstream=null;try(client){
  client.setSoTimeout(15000);InputStream input=new BufferedInputStream(client.getInputStream());Request r=parse(input);
  if(closed||!authorized.test(client.getInetAddress()))return;
  upstream=dialer.connect(r.host,r.port);sockets.add(upstream);requests.incrementAndGet();upstream.setSoTimeout(30000);client.setSoTimeout(30000);
  if(closed){upstream.close();return;}
  if(r.tunnel)write(client,"HTTP/1.1 200 Connection Established\r\n\r\n");
  else write(upstream,r.firstLine+"\r\n"+String.join("\r\n",r.headers)+"\r\n\r\n");
  Socket remote=upstream;
  Future<?> send=workers.submit(()->{try{copy(input,remote.getOutputStream());remote.shutdownOutput();}catch(IOException ignored){}});
  try{copy(remote.getInputStream(),client.getOutputStream());}finally{send.cancel(true);}
 }catch(IOException|RejectedExecutionException e){failures.incrementAndGet();/* Do not record URLs, cookies, credentials or bodies. */}
 finally {sockets.remove(client);if(upstream!=null){sockets.remove(upstream);try{upstream.close();}catch(IOException ignored){}}}}
 static void copy(InputStream input,OutputStream output)throws IOException {byte[] buffer=new byte[16384];int n;while((n=input.read(buffer))!=-1){output.write(buffer,0,n);output.flush();}}
 public void close(){closed=true;try{listener.close();}catch(IOException ignored){}for(Socket socket:sockets)try{socket.close();}catch(IOException ignored){}sockets.clear();workers.shutdownNow();}
}
