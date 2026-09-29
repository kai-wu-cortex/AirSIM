# AirSIM Android Phone Control

Android 16 validation app for the Samsung/AVF deployment. Android Telecom owns carrier call state and actions; the Linux Agent owns Push, Relay credentials, media, and diagnostics.

## Build and test

```sh
./test.sh
./build.sh
```

The app must be selected by the user as the default phone app. Its foreground watchdog notification is required by Android and deliberately uses a low-importance, silent channel. Ordinary incoming calls default to `remote_silent`; emergency calls always fall back to the preloaded system dialer.

## Shizuku PCM bridge

The development build embeds Shizuku API 13.1.5 and runs the Samsung PCM bridge in a daemon `UserService` with shell UID 2000. Install the official Shizuku manager, start it with wireless debugging, then grant AirSIM access from the in-app Shizuku section. The bridge follows the current `avf_tap_fixed` address and restarts while Shizuku remains available.

In `remote_silent` mode, call-state transitions ask the Shizuku service to mute `STREAM_VOICE_CALL` with `cmd audio`, verify the mute, and restore the previous mute state when the call ends. The App never treats its ordinary UID's volume call as proof that Samsung Telephony output is muted.

For this dedicated validation phone, granting Shizuku `WRITE_SECURE_SETTINGS` allows Shizuku 13.6 on Android 13+ to enable wireless debugging and start itself from its boot receiver. This is a device provisioning step, not an App runtime permission.

Configuration accepts only the AVF private `10.185.5.0/24` Agent endpoint. The bearer token is stored in Android private preferences and is never committed or printed in logs.
