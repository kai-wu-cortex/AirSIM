package android.telecom;
public record PhoneAccount(PhoneAccountHandle handle, String label, int capabilities) {
    public static final int CAPABILITY_SIM_SUBSCRIPTION = 4;
    public boolean hasCapabilities(int flags) { return (capabilities & flags) == flags; }
    public CharSequence getLabel() { return label; }
}
