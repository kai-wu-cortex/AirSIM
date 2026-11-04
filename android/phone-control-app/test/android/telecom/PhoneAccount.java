package android.telecom;
public record PhoneAccount(PhoneAccountHandle handle, String label, int capabilities,
        android.net.Uri address, android.net.Uri subscriptionAddress) {
    public PhoneAccount(PhoneAccountHandle handle, String label, int capabilities) {
        this(handle, label, capabilities, null, null);
    }
    public static final int CAPABILITY_SIM_SUBSCRIPTION = 4;
    public boolean hasCapabilities(int flags) { return (capabilities & flags) == flags; }
    public CharSequence getLabel() { return label; }
    public android.net.Uri getAddress() { return address; }
    public android.net.Uri getSubscriptionAddress() { return subscriptionAddress; }
}
