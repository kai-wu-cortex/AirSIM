package com.airsim.f50wifi;
import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

final class PortalHttp {
 final F50WifiServer server;
 final SecureRandom random=new SecureRandom();
 final Map<String,Session> sessions=new ConcurrentHashMap<>();
 final ExecutorService clients=new ThreadPoolExecutor(2,4,30,TimeUnit.SECONDS,new ArrayBlockingQueue<>(12));
 int failed=0;long lockedUntil=0;
 static final class Session {final String csrf;final long expires;Session(String c){csrf=c;expires=System.currentTimeMillis()+8*60*60*1000L;}}
 PortalHttp(F50WifiServer server)throws Exception {this.server=server;synchronized(server.storageLock){if(!server.settings.has("password_hash")){
  String code=String.format(Locale.ROOT,"%04d%04d%04d",random.nextInt(10000),random.nextInt(10000),random.nextInt(10000));
  setPassword(code);F50WifiServer.write(new File(server.directory,"initial-access-code"),code);
 }}}
 String token(){byte[] b=new byte[32];random.nextBytes(b);return Base64.getUrlEncoder().withoutPadding().encodeToString(b);}
 static String hash(String password,String salt)throws Exception {PBEKeySpec spec=new PBEKeySpec(password.toCharArray(),Base64.getDecoder().decode(salt),120000,256);try{SecretKeyFactory factory=SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");byte[] result=factory.generateSecret(spec).getEncoded();return Base64.getEncoder().encodeToString(result);}finally{spec.clearPassword();}}
 void setPassword(String password)throws Exception {byte[] salt=new byte[16];random.nextBytes(salt);String encoded=Base64.getEncoder().encodeToString(salt);synchronized(server.storageLock){server.settings.put("password_salt",encoded).put("password_hash",hash(password,encoded));server.persist();}}
 synchronized boolean authenticate(String password)throws Exception {
  if(System.currentTimeMillis()<lockedUntil)return false;
  boolean ok; synchronized(server.storageLock){ok=PortalRules.same(hash(password,server.settings.getString("password_salt")),server.settings.getString("password_hash"));}
  if(ok)failed=0;else if(++failed>=5){failed=0;lockedUntil=System.currentTimeMillis()+60000;}
  return ok;
 }
 void start()throws IOException {
  ServerSocket socket=new ServerSocket();socket.setReuseAddress(true);socket.bind(new InetSocketAddress(8088),12);
  Thread accept=new Thread(()->{while(true)try{Socket peer=socket.accept();try{clients.execute(()->handle(peer));}catch(RejectedExecutionException e){peer.close();}}catch(IOException ignored){}},"f50-wifi-http");accept.setDaemon(true);accept.start();
 }
 static String line(InputStream in,int limit)throws IOException {ByteArrayOutputStream out=new ByteArrayOutputStream();for(int i=0;i<limit;i++){int c=in.read();if(c<0)throw new EOFException();if(c=='\n'){byte[] b=out.toByteArray();return new String(b,0,b.length>0&&b[b.length-1]=='\r'?b.length-1:b.length,StandardCharsets.US_ASCII);}out.write(c);}throw new IOException("line too long");}
 void reply(Socket s,int status,String type,byte[] data,String cookie)throws IOException {
  String h="HTTP/1.1 "+status+" "+(status==200?"OK":"Request result")+"\r\nContent-Type: "+type+"\r\nContent-Length: "+data.length+"\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'\r\n";
  if(cookie!=null)h+="Set-Cookie: f50wifi_session="+cookie+"; Path=/; HttpOnly; SameSite=Strict; Max-Age=28800\r\n";
  OutputStream out=s.getOutputStream();out.write((h+"\r\n").getBytes(StandardCharsets.US_ASCII));out.write(data);out.flush();
 }
 void json(Socket s,int status,JSONObject value,String cookie)throws IOException {reply(s,status,"application/json; charset=utf-8",value.toString().getBytes(StandardCharsets.UTF_8),cookie);}
 void error(Socket s,int status,String message)throws Exception {json(s,status,new JSONObject().put("error",message),null);}
 void handle(Socket s){try(s){try{
  s.setSoTimeout(6000);if(!PortalRules.local(s.getInetAddress())){error(s,403,"仅允许本地网络访问。");return;}
  InputStream in=new BufferedInputStream(s.getInputStream());String[] request=line(in,2048).split(" ");if(request.length!=3){error(s,400,"请求无效。");return;}
  String method=request[0],path=request[1];Map<String,String> headers=new HashMap<>();int total=0;
  while(true){String l=line(in,4096);total+=l.length();if(total>PortalRules.MAX_HEADERS)throw new IOException("headers too large");if(l.isEmpty())break;int p=l.indexOf(':');if(p<1)throw new IOException("invalid header");String k=l.substring(0,p).toLowerCase(Locale.ROOT);if(headers.putIfAbsent(k,l.substring(p+1).trim())!=null)throw new IOException("duplicate header");}
  if(!PortalRules.validHost(headers.get("host"))){error(s,403,"请使用设备 IP 或 f50wifi.local 打开页面。");return;}
  if(headers.containsKey("transfer-encoding")){error(s,400,"请求格式不受支持。");return;}
  if(method.equals("GET")&&path.equals("/")){reply(s,200,"text/html; charset=utf-8",WebPage.HTML.getBytes(StandardCharsets.UTF_8),null);return;}
  if(method.equals("GET")&&path.matches("/hotel/[A-Za-z0-9_-]{32}\\.pac")){
   String pac=server.hotel.pac(path.substring(7,path.length()-4),s.getInetAddress());
   if(pac==null){error(s,403,"请在认证热点内登录配网页并启用认证通道。");return;}
   reply(s,200,"application/x-ns-proxy-autoconfig",pac.getBytes(StandardCharsets.US_ASCII),null);return;
  }
  if(!path.startsWith("/api/")){error(s,404,"页面不存在。");return;}
  if(!method.equals("GET")&&!method.equals("POST")){error(s,405,"请求方法不支持。");return;}
  JSONObject body=new JSONObject();
  if(method.equals("POST")){
   if(!PortalRules.validOrigin(headers.get("origin"),headers.get("host"))){error(s,403,"来源验证失败，请刷新此页面。");return;}
   if(!headers.getOrDefault("content-type","").toLowerCase(Locale.ROOT).startsWith("application/json")){error(s,415,"需要 JSON 请求。");return;}
   int size=Integer.parseInt(headers.getOrDefault("content-length","-1"));if(size<0||size>PortalRules.MAX_BODY){error(s,413,"请求过大。");return;}
   byte[] bytes=in.readNBytes(size);if(bytes.length!=size)throw new EOFException();body=new JSONObject(new String(bytes,StandardCharsets.UTF_8));
  }
  if(method.equals("POST")&&path.equals("/api/login")){
   String password=body.optString("password");if(password.length()>64||!authenticate(password)){error(s,401,"管理密码不正确；连续失败后请等待一分钟。");return;}
   server.openedSetup();if(sessions.size()>32)sessions.clear();String key=token();Session session=new Session(token());sessions.put(key,session);json(s,200,new JSONObject().put("csrf",session.csrf),key);return;
  }
  String key="";for(String part:headers.getOrDefault("cookie","").split(";")){part=part.trim();if(part.startsWith("f50wifi_session="))key=part.substring(16);}
  Session session=sessions.get(key);if(session==null||System.currentTimeMillis()>session.expires){error(s,401,"请先输入管理密码。");return;}
  if(method.equals("GET")&&path.equals("/api/status")){json(s,200,server.status().put("csrf",session.csrf),null);return;}
  if(method.equals("GET")&&path.equals("/api/networks")){json(s,200,new JSONObject().put("networks",server.scans()),null);return;}
  if(!method.equals("POST")){error(s,404,"页面不存在。");return;}
  if(!PortalRules.same(session.csrf,headers.get("x-csrf-token"))){error(s,403,"会话已更新，请刷新页面后重试。");return;}
  if(path.equals("/api/hotel/authorize")){server.hotel.authorize(s.getInetAddress());json(s,200,new JSONObject().put("ok",true),null);return;}
  if(path.equals("/api/logout")){sessions.remove(key);json(s,200,new JSONObject().put("ok",true),"");return;}
  if(path.equals("/api/password")){
   String p=body.optString("password");if(p.length()<8||p.length()>64)throw new IllegalArgumentException("管理密码需为 8–64 个字符。");setPassword(p);new File(server.directory,"initial-access-code").delete();sessions.clear();server.hotel.stop("管理密码已更新，请重新登录开启认证通道");json(s,200,new JSONObject().put("ok",true),"");return;
  }
  try{json(s,200,server.action(path,body),null);}catch(IllegalArgumentException e){error(s,400,e.getMessage());}
 }catch(JSONException|NumberFormatException failure){error(s,400,"请求内容无效，请刷新页面后重试。");}catch(IllegalArgumentException failure){error(s,400,failure.getMessage());}catch(IOException failure){error(s,400,"请求不完整或格式无效。");}catch(Exception failure){System.err.println("http_request_failed="+failure.getClass().getSimpleName());error(s,500,"设备操作未完成，请稍后重试。");}}catch(Exception ignored){}}
}
