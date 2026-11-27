# SMS native navigation and chrome placement

- Compact iPhone layout now uses NavigationStack with a real destination rather
  than changing NavigationSplitView's preferred compact column. Expanded iPad
  layout retains its sidebar/detail split.
- Keep the system back button and native interactive pop. Remove the timeline's
  discrete UISwipeGestureRecognizer. A short edge drag can cancel; a completed
  pop updates the existing showingConversation binding.
- Put the avatar and sender in the navigation bar's principal item, with a
  compact avatar fitting the native bar. Remove the separate 104-point header
  and its timeline inset.
- Remove the outer explicit animation on conversation selection. Tab-bar hiding
  belongs to the pushed destination. Apply composer height measurements without
  implicit animation, avoiding animation of the initial measured content inset.
- Retain the edge-to-edge scrolling surface, native soft edge effects, explicit
  expanded-layout back action, keyboard avoidance and existing SMS send logic.

## Verification

- Signed device build passed: `/tmp/airsim-sms-native-push-build.log`.
- First UI run exposed an ambiguous test selector: the native back button is
  also labeled SMS. The hidden-tab assertion now specifically queries tabBars.
- The same run stalled in XCTest's idle synchronization on re-entry. A process
  sample showed the app main thread idle in CFRunLoop, not a navigation loop.
  Screenshot `/tmp/airsim-sms-native-push-current.png` confirms the elevated
  avatar and stable resting composer. The test simulator was restarted without
  erasing data, and targeted regressions were restarted with bounded timeouts.
- No live SMS, calls or backend deployment were performed.

## Resumed verification

- Temporary outputs from the preceding run were no longer present. Rebuilt the
  current worktree successfully for the device, Debug 0.9.8 (190), with local
  signing overrides only. Log: `/tmp/airsim-sms-resume-device.log`.
- Simulator test binaries also compiled. The navigation regression reached a
  native back-button tap and subsequently the list and tab switch, but exceeded
  the execution allowance while XCTest waited for App animations to complete.
  This run is **not a passing regression**. Log:
  `/tmp/airsim-sms-resume-test.log`.
- Moved the short-cancel / long-complete edge-drag checks to the first entry in
  the test so they do not depend on completing the repeated-navigation loop.
  The focused retry could not launch its runner (NSMachErrorDomain -308,
  simulator server died); interactive gesture validation remains outstanding.
  Log: `/tmp/airsim-sms-gesture-first.log`.
- Physical iPhone Air remains unavailable to CoreDevice despite reconnect
  attempts; installation failed with error 4016 (trusted connectivity unavailable).
  No installation or data removal occurred in this resumed run. Log:
  `/tmp/airsim-sms-install.log`.

## Wireless installation completed

- After the user provided the iPhone Wi-Fi address, local reachability succeeded.
  CoreDevice subsequently rediscovered the already-paired iPhone. Installation
  used native `devicectl`; the fallback Python installer was not run.
- Installed Debug 0.9.8 (190) over the existing app without uninstalling or
  clearing data. Device app inventory confirms bundle `com.eric3u.airsim`,
  version 190; installation database sequence 4648.
- Evidence: `/tmp/airsim-sms-wireless-install-result.json` and
  `/tmp/airsim-sms-wireless-app.json`. Automated gesture-test limitations above
  still apply; installation does not establish that those tests passed.
