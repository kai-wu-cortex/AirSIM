package com.airsim.phonecontrol;
import android.content.Context;
public class AndroidBatteryStatusTests {
    public static void main(String[] args) {
        if (AndroidBatteryStatus.percent(0, 100) != 0
                || AndroidBatteryStatus.percent(100, 100) != 100
                || AndroidBatteryStatus.percent(41, 50) != 82
                || AndroidBatteryStatus.percent(-1, 100) != -1
                || AndroidBatteryStatus.percent(3, 0) != -1
                || AndroidBatteryStatus.percent(101, 100) != -1
                || AndroidBatteryStatus.snapshot(new Context()) != null) throw new AssertionError("battery normalization");
        System.out.println("AndroidBatteryStatusTests passed");
    }
}
