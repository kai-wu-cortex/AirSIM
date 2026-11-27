# SMS return motion and inbox scroll edge — build 198

## Cause and changes

- The inbox used the automatic scroll edge treatment after moving its title/search into the list. Apply the same native `.scrollEdgeEffectStyle(.soft, for: .top)` used in Settings on iOS 26+, with the existing older-system presentation retained. Keep the inline navigation title so selecting a conversation does not reflow the inbox.
- Revealing the tab bar in `viewWillAppear` changes the outgoing editor host's bottom safe area at the start of an interactive pop. Build 197 animated that live host, exposing an upward layout jump before the requested fade.
- Capture the already rendered composer with UIKit `snapshotView(afterScreenUpdates: false)` before revealing tabs. Crossfade this temporary, non-interactive view at its existing screen coordinates with the native tab bar, using the same navigation transition coordinator as the top buttons. Remove the added translation and scaling. The editor and its draft remain in their original host.
- On cancellation, restore the hidden tab state and settle layout before revealing the real composer. Remove the temporary view on completion, cancellation, and failure to enqueue the coordinator animation. No custom gesture recognizer or persistent duplicate tab/editor was introduced.
- Avatar/number dimensions, SMS submission, pairing, and call routing are unchanged by this follow-up.

## Verification

- Device signed Debug build 198 passed: `/tmp/airsim-sms-198-build.log`.
- Installed over the existing app on iPhone Air, preserving data; device installation succeeded (database sequence 4840).
- Simulator UI regression passed: `SMSNavigationUITests/testThreadBackWithKeyboardAndEdgeOverlays`, 1 test / 0 failures in 95.342 seconds. Covers repeated navigation, short cancelled drag, long completed drag, keyboard/tap return, immediately reachable tabs, inbox row position, and full-size header hit targets. Log: `/tmp/airsim-sms-198-test.log`.
- Added a simulator-only long inbox to exercise the edge under actual scrolling. Inspected the inbox screenshot and 11-second slow-drag video segment: continuous top blur, stationary composer vertical position during drag onset, and tab handoff/cancellation.
- Artifacts: `/tmp/airsim-sms-198-attachments/754543C8-3EBC-4550-9637-40FDEAEAF052.png`, `/tmp/airsim-sms-198-return-preview.mp4`.
- `git diff --check` passed. No real SMS or calls were initiated.

Apple references: [scrollEdgeEffectStyle](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)), [snapshotView](https://developer.apple.com/documentation/uikit/uiview/snapshotview(afterscreenupdates:)).
