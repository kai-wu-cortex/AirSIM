package com.airsim.f50dsds;
import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.*;
import android.provider.Settings;
import java.io.*;
import java.security.MessageDigest;

/** Shell-only, single-purpose workaround for the verified B28 secondary-SIM timer. */
public final class DsdsProvider extends ContentProvider {
 private static final String KEY="car_mode_dual_sim_switch";
 private static final String FRAMEWORK_SHA256="600edb6d53fefa464503a3d8958ccd15befce847648528a4b0439df8c738a2a0";
 private boolean supported;
 @Override public boolean onCreate(){
  try(InputStream in=new FileInputStream("/system/framework/vendor-telephony-common.jar")){
   MessageDigest digest=MessageDigest.getInstance("SHA-256");byte[] buf=new byte[65536];int n;
   while((n=in.read(buf))!=-1)digest.update(buf,0,n);
   StringBuilder hex=new StringBuilder();for(byte b:digest.digest())hex.append(String.format(java.util.Locale.ROOT,"%02x",b&255));
   supported=FRAMEWORK_SHA256.equals(hex.toString());
  }catch(Exception ignored){supported=false;}
  return true;
 }
 @Override public synchronized Bundle call(String method,String arg,Bundle extras){
  int uid=Binder.getCallingUid();if(uid!=2000&&uid!=0)throw new SecurityException("USB shell only");
  if(!"pulse".equals(method)&&!"status".equals(method))throw new IllegalArgumentException("Unsupported operation");
  Bundle result=new Bundle();result.putBoolean("supported",supported);
  if(!supported){result.putString("state","unsupported_firmware");return result;}
  long identity=Binder.clearCallingIdentity();
  try{
   ContentResolver resolver=getContext().getContentResolver();
   if("pulse".equals(method)&&"1".equals(Settings.System.getString(resolver,KEY))){
    // Never write 0 or toggle either radio off. Re-notifying the unchanged 1
    // replaces B28's pending 60-second no-service shutdown check.
    resolver.notifyChange(Settings.System.getUriFor(KEY),null,false);
   }
   result.putString("state","1".equals(Settings.System.getString(resolver,KEY))?"enabled":"disabled");
   return result;
  }finally{Binder.restoreCallingIdentity(identity);}
 }
 @Override public Cursor query(Uri u,String[] p,String s,String[] a,String o){throw new UnsupportedOperationException();}
 @Override public String getType(Uri u){return null;}
 @Override public Uri insert(Uri u,ContentValues v){throw new UnsupportedOperationException();}
 @Override public int update(Uri u,ContentValues v,String s,String[] a){throw new UnsupportedOperationException();}
 @Override public int delete(Uri u,String s,String[] a){throw new UnsupportedOperationException();}
}
