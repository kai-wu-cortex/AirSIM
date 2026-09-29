package main

import (
	"os"
	"strings"
)

const runtimeProfileEnvironment = "DJONEHUB_RUNTIME_PROFILE"

type runtimeProfile struct {
	Name                string
	Platform            string
	RequiresModem       bool
	DirectModule        bool
	CallAudio           bool
	NativeContacts      bool
	NetworkPolicyNative bool
	WRTLite             bool
	AndroidTelecom      bool
}

func runtimeProfileFrom(value string) runtimeProfile {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "android-avf", "android-vm":
		return runtimeProfile{
			Name:           "android-avf",
			Platform:       "android-avf-arm64",
			AndroidTelecom: true,
		}
	case "qdc507":
		return runtimeProfile{
			Name:                "qdc507",
			Platform:            "qdc507-armv7",
			RequiresModem:       true,
			DirectModule:        true,
			CallAudio:           true,
			NativeContacts:      true,
			NetworkPolicyNative: true,
			WRTLite:             true,
		}
	default:
		return runtimeProfileFrom("android-avf")
	}
}

func currentRuntimeProfile() runtimeProfile {
	return runtimeProfileFrom(os.Getenv(runtimeProfileEnvironment))
}
