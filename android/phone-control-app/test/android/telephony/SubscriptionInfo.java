package android.telephony;
public class SubscriptionInfo {
    public int slot;
    public int subscriptionId;
    public boolean embedded;
    public String number = "";
    public String displayName = "";
    public String carrierName = "Carrier";
    public String countryIso = "";
    public int dataRoaming = 0;

    public int getSimSlotIndex() { return slot; }
    public int getSubscriptionId() { return subscriptionId; }
    public boolean isEmbedded() { return embedded; }
    public CharSequence getCarrierName() { return carrierName; }
    public CharSequence getDisplayName() { return displayName; }
    public String getNumber() { return number; }
    public String getCountryIso() { return countryIso; }
    public int getDataRoaming() { return dataRoaming; }
}
