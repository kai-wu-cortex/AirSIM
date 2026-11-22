package com.airsim.phonecontrol;

import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;

final class PrivilegedBridgeClient implements PrivilegedBridgeCoordinator.Transport {
    private final IBinder binder;

    PrivilegedBridgeClient(IBinder binder) {
        if (binder == null || !binder.pingBinder()) throw new IllegalArgumentException("privileged binder unavailable");
        this.binder = binder;
    }

    @Override public String startBridge() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_START_BRIDGE, false, false);
    }

    @Override public String status() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_STATUS, false, false);
    }

    @Override public String setLocalOutputMuted(boolean muted) throws RemoteException {
        return setLocalOutputMuted(muted, PrivilegedBridgeProtocol.TRANSPORT_VOWLAN);
    }

    @Override public String setLocalOutputMuted(boolean muted, String transport) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeInt(muted ? 1 : 0);
            data.writeString(PrivilegedBridgeProtocol.TRANSPORT_VOBLE.equals(transport)
                    ? PrivilegedBridgeProtocol.TRANSPORT_VOBLE
                    : PrivilegedBridgeProtocol.TRANSPORT_VOWLAN);
            if (!binder.transact(PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED, data, reply, 0)) {
                throw new RemoteException("privileged transaction rejected");
            }
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    @Override public String setLocalOutputMuted(boolean muted, String transport, String policy) throws RemoteException {
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeInt(muted ? 1 : 0);
            data.writeString(transport);
            data.writeString(policy);
            if (!binder.transact(PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_POLICY, data, reply, 0))
                throw new RemoteException("请重新启动权限服务，以应用通话音量策略");
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally { reply.recycle(); data.recycle(); }
    }

    @Override public String audioSnapshot() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_AUDIO_SNAPSHOT, false, false);
    }

    String ensureDialerRole() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_ENSURE_DIALER_ROLE, false, false);
    }

    String smsPreflight() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_SMS_PREFLIGHT, false, false);
    }

    int resolveSmsSubscription(String key) throws RemoteException {
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeString(key);
            if (!binder.transact(PrivilegedBridgeProtocol.TRANSACTION_RESOLVE_SMS_SUBSCRIPTION, data, reply, 0)) return -1;
            reply.readException();
            try { return Integer.parseInt(reply.readString()); }
            catch (RuntimeException error) { return -1; }
        } finally { reply.recycle(); data.recycle(); }
    }

    String recentSms(long afterId, long cutoffMillis, int limit) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeLong(afterId);
            data.writeLong(cutoffMillis);
            data.writeInt(limit);
            if (!binder.transact(PrivilegedBridgeProtocol.TRANSACTION_RECENT_SMS,
                    data, reply, 0)) {
                throw new RemoteException("privileged SMS inbox transaction rejected");
            }
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    String sendSms(String destination, String body, int subscriptionId) throws RemoteException {
        return sendSms(destination, body, subscriptionId, null);
    }

    String sendSms(String destination, String body, int subscriptionId,
            java.util.ArrayList<android.app.PendingIntent> sentIntents) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            data.writeString(destination);
            data.writeString(body);
            data.writeInt(subscriptionId);
            if (sentIntents != null) data.writeTypedList(sentIntents);
            int transaction = sentIntents == null ? PrivilegedBridgeProtocol.TRANSACTION_SEND_SMS
                    : PrivilegedBridgeProtocol.TRANSACTION_SEND_SMS_CONFIRMED;
            if (!binder.transact(transaction, data, reply, 0)) {
                // Unsupported transaction is known not to have invoked a sender.
                return "error:prepare:unsupported_transaction";
            }
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }

    private String transact(int code, boolean hasBoolean, boolean value) throws RemoteException {
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(PrivilegedBridgeProtocol.DESCRIPTOR);
            if (hasBoolean) data.writeInt(value ? 1 : 0);
            if (!binder.transact(code, data, reply, 0)) throw new RemoteException("privileged transaction rejected");
            reply.readException();
            String result = reply.readString();
            return result == null ? "" : result;
        } finally {
            reply.recycle();
            data.recycle();
        }
    }
}
