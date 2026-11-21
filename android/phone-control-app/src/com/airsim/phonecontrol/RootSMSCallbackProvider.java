package com.airsim.phonecontrol;

import android.app.PendingIntent;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.SystemClock;
import java.util.ArrayList;

/** Transfers App-owned sent callbacks over Binder to one authorized root SMS helper. */
public final class RootSMSCallbackProvider extends ContentProvider {
    static final String SUFFIX = ".root-sms-callbacks";
    static final String CLAIM = "claim_sent_callbacks";
    static final String CALLBACKS = "callbacks";
    private static final RootSMSCallbackStore<ArrayList<PendingIntent>> STORE = new RootSMSCallbackStore<>();

    static String register(ArrayList<PendingIntent> callbacks) {
        return STORE.register(new ArrayList<>(callbacks), SystemClock.elapsedRealtime());
    }
    static void revoke(String token) { STORE.revoke(token); }

    @Override public boolean onCreate() { return true; }
    @Override public Bundle call(String method, String arg, Bundle extras) {
        if (Binder.getCallingUid() != 0) throw new SecurityException("root required");
        if (!CLAIM.equals(method)) throw new IllegalArgumentException("unsupported operation");
        Bundle result = new Bundle();
        result.putParcelableArrayList(CALLBACKS, STORE.claim(Binder.getCallingUid(), arg, SystemClock.elapsedRealtime()));
        return result;
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        throw new UnsupportedOperationException();
    }
    @Override public String getType(Uri uri) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
