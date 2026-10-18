package com.airsim.phonecontrol;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.telecom.Call;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;
import android.telephony.SmsManager;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import org.json.JSONArray;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class SIMSlotManager {
    private SIMSlotManager() {}

    public static List<SIMSlotInfo> getActiveSlots(Context context) {
        if (context == null) return List.of();
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
                != PackageManager.PERMISSION_GRANTED) {
            return List.of();
        }

        TelephonyManager telephony = context.getSystemService(TelephonyManager.class);
        Map<Integer, PhoneAccountHandle> subToHandle = new HashMap<>();
        try {
            TelecomManager telecom = context.getSystemService(TelecomManager.class);
            if (telecom != null) {
                for (PhoneAccountHandle handle : telecom.getCallCapablePhoneAccounts()) {
                    PhoneAccount account = telecom.getPhoneAccount(handle);
                    if (account == null || !account.hasCapabilities(PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION)) {
                        continue;
                    }
                    int subId = -1;
                    if (telephony != null) {
                        if (Build.VERSION.SDK_INT >= 30) {
                            subId = telephony.getSubscriptionId(handle);
                        } else {
                            TelephonyManager specific = telephony.createForPhoneAccountHandle(handle);
                            if (specific != null) {
                                try {
                                    subId = Integer.parseInt(specific.getNetworkSpecifier());
                                } catch (Exception ignored) {}
                            }
                        }
                    }
                    if (subId >= 0) {
                        subToHandle.put(subId, handle);
                    }
                }
            }
        } catch (Throwable ignored) {}

        List<SIMSlotInfo> slots = new ArrayList<>();
        try {
            SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
            if (subscriptions != null) {
                List<SubscriptionInfo> subList = subscriptions.getActiveSubscriptionInfoList();
                int defaultVoiceId = SubscriptionManager.getDefaultVoiceSubscriptionId();
                int defaultSmsId = SmsManager.getDefaultSmsSubscriptionId();
                boolean hasReadNumbers = context.checkSelfPermission(Manifest.permission.READ_PHONE_NUMBERS)
                        == PackageManager.PERMISSION_GRANTED;

                if (subList != null && !subList.isEmpty()) {
                    for (SubscriptionInfo info : subList) {
                        int slotIndex = info.getSimSlotIndex();
                        int subId = info.getSubscriptionId();
                        String carrier = info.getCarrierName() == null ? "" : info.getCarrierName().toString().trim();
                        boolean isEmbedded = info.isEmbedded();
                        String countryIso = "";
                        try {
                            countryIso = info.getCountryIso() == null ? "" : info.getCountryIso().trim();
                        } catch (Throwable ignored) {}

                        String number = "";
                        if (hasReadNumbers) {
                            if (Build.VERSION.SDK_INT >= 33) {
                                try {
                                    number = subscriptions.getPhoneNumber(subId);
                                } catch (Throwable ignored) {}
                            }
                            if (number == null || number.length() == 0) {
                                try {
                                    number = info.getNumber();
                                } catch (Throwable ignored) {}
                            }
                        }
                        if (number == null) number = "";
                        number = number.trim();

                        String displayName = "";
                        try {
                            displayName = info.getDisplayName() == null ? "" : info.getDisplayName().toString().trim();
                        } catch (Throwable ignored) {}
                        if (displayName.length() == 0 || displayName.equalsIgnoreCase(carrier)) {
                            String slotPrefix = isEmbedded ? "eSIM" : "SIM " + (slotIndex >= 0 ? (slotIndex + 1) : 1);
                            displayName = carrier.length() == 0 ? slotPrefix : slotPrefix + " · " + carrier;
                        }

                        boolean isDefaultVoice = (subId >= 0 && subId == defaultVoiceId);
                        boolean isDefaultSms = (subId >= 0 && subId == defaultSmsId);
                        PhoneAccountHandle handle = subToHandle.get(subId);

                        String simState = "ready";
                        if (telephony != null) {
                            try {
                                int state = telephony.getSimState(slotIndex);
                                simState = switch (state) {
                                    case TelephonyManager.SIM_STATE_ABSENT -> "absent";
                                    case TelephonyManager.SIM_STATE_PIN_REQUIRED -> "pin_required";
                                    case TelephonyManager.SIM_STATE_PUK_REQUIRED -> "puk_required";
                                    case TelephonyManager.SIM_STATE_NETWORK_LOCKED -> "network_locked";
                                    case TelephonyManager.SIM_STATE_READY -> "ready";
                                    case TelephonyManager.SIM_STATE_NOT_READY -> "not_ready";
                                    case TelephonyManager.SIM_STATE_PERM_DISABLED -> "disabled";
                                    case TelephonyManager.SIM_STATE_CARD_IO_ERROR -> "error";
                                    case TelephonyManager.SIM_STATE_CARD_RESTRICTED -> "restricted";
                                    default -> "unknown";
                                };
                            } catch (Throwable ignored) {}
                        }

                        slots.add(new SIMSlotInfo(
                                slotIndex, subId, carrier, displayName, number,
                                countryIso, isEmbedded, isDefaultVoice, isDefaultSms, simState, handle));
                    }
                }
            }
        } catch (Throwable ignored) {}

        slots.sort(Comparator.comparingInt(SIMSlotInfo::slotIndex));
        return Collections.unmodifiableList(slots);
    }

    public static JSONArray getSlotsJSON(Context context) {
        JSONArray array = new JSONArray();
        for (SIMSlotInfo slot : getActiveSlots(context)) {
            array.put(slot.toJSON());
        }
        return array;
    }

    public static SIMSlotInfo getSlotByIndex(Context context, int slotIndex) {
        if (slotIndex < 0) return null;
        for (SIMSlotInfo slot : getActiveSlots(context)) {
            if (slot.slotIndex() == slotIndex) return slot;
        }
        return null;
    }

    public static SIMSlotInfo getSlotBySubId(Context context, int subId) {
        if (subId < 0) return null;
        for (SIMSlotInfo slot : getActiveSlots(context)) {
            if (slot.subscriptionId() == subId) return slot;
        }
        return null;
    }

    public static SIMSlotInfo slotForCall(Context context, Call call) {
        if (call == null) return null;
        Call.Details details = call.getDetails();
        if (details == null) return null;
        PhoneAccountHandle handle = details.getAccountHandle();
        SIMSlotInfo fromHandle = slotForAccountHandle(context, handle);
        if (fromHandle != null) return fromHandle;

        Bundle extras = details.getExtras();
        if (extras != null) {
            int subId = extras.getInt("android.telecom.extra.SUBSCRIPTION_ID",
                    extras.getInt("android.telephony.extra.SUBSCRIPTION_INDEX",
                    extras.getInt("subscription", -1)));
            if (subId >= 0) {
                SIMSlotInfo match = getSlotBySubId(context, subId);
                if (match != null) return match;
            }
            int slotIdx = extras.getInt("simSlot", extras.getInt("slot", -1));
            if (slotIdx >= 0) {
                SIMSlotInfo match = getSlotByIndex(context, slotIdx);
                if (match != null) return match;
            }
        }
        return null;
    }

    public static SIMSlotInfo slotForAccountHandle(Context context, PhoneAccountHandle handle) {
        if (handle == null) return null;
        List<SIMSlotInfo> slots = getActiveSlots(context);
        for (SIMSlotInfo slot : slots) {
            if (handle.equals(slot.accountHandle())) return slot;
        }

        try {
            TelephonyManager telephony = context.getSystemService(TelephonyManager.class);
            int subId = -1;
            if (telephony != null) {
                if (Build.VERSION.SDK_INT >= 30) {
                    subId = telephony.getSubscriptionId(handle);
                } else {
                    TelephonyManager specific = telephony.createForPhoneAccountHandle(handle);
                    if (specific != null) {
                        try {
                            subId = Integer.parseInt(specific.getNetworkSpecifier());
                        } catch (Exception ignored) {}
                    }
                }
            }
            if (subId >= 0) {
                return getSlotBySubId(context, subId);
            }
        } catch (Throwable ignored) {}

        String handleId = handle.getId();
        if (handleId != null && handleId.length() > 0) {
            for (SIMSlotInfo slot : slots) {
                if (handleId.contains(Integer.toString(slot.subscriptionId()))
                        || (slot.number().length() > 0 && handleId.contains(slot.number()))) {
                    return slot;
                }
            }
        }
        return null;
    }

    public static SIMSlotInfo slotForSMS(Context context, int subId, int slotIndex) {
        if (subId >= 0) {
            SIMSlotInfo match = getSlotBySubId(context, subId);
            if (match != null) return match;
        }
        if (slotIndex >= 0) {
            SIMSlotInfo match = getSlotByIndex(context, slotIndex);
            if (match != null) return match;
        }
        return null;
    }

    public static SIMSlotInfo resolveSlot(Context context, int slotId, String slotName) {
        if (slotId >= 0) {
            SIMSlotInfo match = getSlotByIndex(context, slotId);
            if (match != null) return match;
        }
        int parsed = parseSlotIdentifier(slotName);
        if (parsed >= 0) {
            return getSlotByIndex(context, parsed);
        }
        return null;
    }

    public static int parseSlotIdentifier(String slot) {
        if (slot == null || slot.length() == 0) return -1;
        String normalized = slot.trim().toLowerCase(Locale.ROOT);
        if (normalized.equals("sim1") || normalized.equals("slot1") || normalized.equals("0")) return 0;
        if (normalized.equals("sim2") || normalized.equals("slot2") || normalized.equals("1")) return 1;
        if (normalized.equals("sim3") || normalized.equals("slot3") || normalized.equals("2")) return 2;
        try {
            int val = Integer.parseInt(normalized);
            return val >= 0 ? val : -1;
        } catch (NumberFormatException ignored) {
            return -1;
        }
    }

    public static Bundle dialExtrasForCommand(Context context, AgentCommand command) {
        SIMSlotInfo target = null;
        if (command != null) {
            if (command.subId >= 0) {
                target = getSlotBySubId(context, command.subId);
            }
            if (target == null && (command.slotId >= 0 || (command.slot != null && command.slot.length() > 0))) {
                target = resolveSlot(context, command.slotId, command.slot);
            }
        }
        if (target != null && target.accountHandle() != null) {
            Bundle extras = new Bundle();
            extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, target.accountHandle());
            return extras;
        }
        return DefaultCallAccount.dialExtras(context);
    }

    private static volatile boolean listenerRegistered = false;
    private static final Object LISTENER_LOCK = new Object();

    public static void registerChangeListener(Context context, Runnable onChange) {
        if (context == null || onChange == null || listenerRegistered) return;
        android.os.Handler mainHandler = new android.os.Handler(android.os.Looper.getMainLooper());
        mainHandler.post(() -> {
            synchronized (LISTENER_LOCK) {
                if (listenerRegistered) return;
                try {
                    SubscriptionManager subscriptions = context.getSystemService(SubscriptionManager.class);
                    if (subscriptions != null) {
                        SubscriptionManager.OnSubscriptionsChangedListener listener =
                                new SubscriptionManager.OnSubscriptionsChangedListener() {
                                    @Override
                                    public void onSubscriptionsChanged() {
                                        super.onSubscriptionsChanged();
                                        BridgeLog.info("sim_slots_subscription_changed");
                                        onChange.run();
                                    }
                                };
                        if (Build.VERSION.SDK_INT >= 30) {
                            subscriptions.addOnSubscriptionsChangedListener(context.getMainExecutor(), listener);
                        } else {
                            subscriptions.addOnSubscriptionsChangedListener(listener);
                        }
                        listenerRegistered = true;
                        BridgeLog.info("sim_slots_listener_registered");
                    }
                } catch (Throwable error) {
                    BridgeLog.error("sim_slots_listener_registration_failed", error);
                }
            }
        });
    }
}
