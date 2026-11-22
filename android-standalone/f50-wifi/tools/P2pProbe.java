import android.content.Context;
import android.net.wifi.p2p.WifiP2pConfig;
import android.net.wifi.p2p.WifiP2pManager;
import android.os.Handler;
import android.os.Looper;
import java.nio.file.Files;

/** Temporary, owner-run P2P group test. Never changes saved infrastructure Wi-Fi. */
public final class P2pProbe {
 public static void main(String[] args)throws Exception {
  Thread.setDefaultUncaughtExceptionHandler((t,e)->{e.printStackTrace();System.exit(1);});
  if(args.length!=1)throw new IllegalArgumentException("private passphrase file required");
  Looper.prepareMainLooper();
  Class<?> at=Class.forName("android.app.ActivityThread");
  Object thread=at.getMethod("systemMain").invoke(null);
  Context system=(Context)at.getMethod("getSystemContext").invoke(thread);
  Context context=system.createPackageContext("com.android.shell",0);
  var op=context.getClass().getDeclaredField("mOpPackageName");op.setAccessible(true);op.set(context,"com.android.shell");
  var attr=context.getClass().getDeclaredField("mAttributionSource");attr.setAccessible(true);
  attr.set(context,new android.content.AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build());
  WifiP2pManager manager=context.getSystemService(WifiP2pManager.class);
  if(manager==null)throw new IllegalStateException("P2P service unavailable");
  Handler handler=new Handler(Looper.getMainLooper());
  WifiP2pManager.Channel channel=manager.initialize(context,Looper.getMainLooper(),()->{System.out.println("CHANNEL_LOST");System.exit(2);});
  WifiP2pConfig config=new WifiP2pConfig.Builder().setNetworkName("DIRECT-F5-ZTE-CN-Setup")
   .setPassphrase(new String(Files.readAllBytes(java.nio.file.Paths.get(args[0])),java.nio.charset.StandardCharsets.UTF_8).trim()).setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_2GHZ)
   .enablePersistentMode(false).build();
  manager.requestGroupInfo(channel,existing->{
   if(existing!=null){System.out.println("REFUSED_EXISTING_GROUP");channel.close();System.exit(3);return;}
   manager.createGroup(channel,config,new WifiP2pManager.ActionListener(){
    public void onSuccess(){System.out.println("CREATE_ACCEPTED");}
    public void onFailure(int reason){System.out.println("CREATE_FAILED "+reason);channel.close();System.exit(4);}
   });
  });
  handler.postDelayed(new Runnable(){public void run(){
   manager.requestGroupInfo(channel,g->System.out.println(g==null?"NO_GROUP":"GROUP interface="+g.getInterface()+" owner="+g.isGroupOwner()+" clients="+g.getClientList().size()));
   handler.postDelayed(this,5000);
  }},5000);
  handler.postDelayed(()->manager.removeGroup(channel,new WifiP2pManager.ActionListener(){
   public void onSuccess(){System.out.println("REMOVED");channel.close();System.exit(0);}
   public void onFailure(int reason){System.out.println("REMOVE_FAILED "+reason);channel.close();System.exit(5);}
  }),300000);
  Looper.loop();
 }
}
