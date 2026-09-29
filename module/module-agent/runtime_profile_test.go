package main

import "testing"

func TestRuntimeProfileDefaultsToAndroidAVF(t *testing.T) {
	profile := runtimeProfileFrom("")
	if profile.Name != "android-avf" || !profile.AndroidTelecom || profile.RequiresModem || profile.DirectModule {
		t.Fatalf("unexpected default profile: %+v", profile)
	}
}

func TestQDC507ProfileRemainsExplicitCompatibilityOnly(t *testing.T) {
	profile := runtimeProfileFrom("qdc507")
	if profile.Name != "qdc507" || !profile.RequiresModem || !profile.DirectModule {
		t.Fatalf("unexpected explicit legacy profile: %+v", profile)
	}
}

func TestAndroidAVFProfileDoesNotClaimModuleHardware(t *testing.T) {
	profile := runtimeProfileFrom("android-avf")
	if profile.Name != "android-avf" || profile.Platform != "android-avf-arm64" {
		t.Fatalf("unexpected Android AVF profile: %+v", profile)
	}
	if profile.RequiresModem || profile.DirectModule || profile.CallAudio || profile.NativeContacts || profile.NetworkPolicyNative || profile.WRTLite {
		t.Fatalf("Android AVF profile must not advertise unavailable hardware: %+v", profile)
	}
	if !profile.AndroidTelecom {
		t.Fatalf("Android AVF profile must route carrier control through Telecom: %+v", profile)
	}
}
