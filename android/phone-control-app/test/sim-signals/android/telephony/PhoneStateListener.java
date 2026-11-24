package android.telephony;
public class PhoneStateListener {
    public static final int LISTEN_NONE = 0, LISTEN_SIGNAL_STRENGTHS = 256;
    public void onSignalStrengthsChanged(SignalStrength value) { }
}
