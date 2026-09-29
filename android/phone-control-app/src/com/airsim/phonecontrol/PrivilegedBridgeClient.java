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

    String status() throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_STATUS, false, false);
    }

    @Override public String setLocalOutputMuted(boolean muted) throws RemoteException {
        return transact(PrivilegedBridgeProtocol.TRANSACTION_SET_LOCAL_OUTPUT_MUTED, true, muted);
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
