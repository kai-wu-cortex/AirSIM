# SMS navigation continuity follow-up

- Animate conversation selection and compact split-column changes. Keep the outgoing compact detail alive during the pop instead of replacing it with the empty-state view immediately.
- Move the conversation back action into the native navigation toolbar, using the same stable toolbar item identity and native glass shell as the list's ellipsis menu. Retain explicit owner-state navigation rather than relying on `dismiss()`.
- Support horizontal left/right swipe-to-return on the message timeline. The recognizer does not cover the composer, is disabled during message/text selection, and does not require vertical scrolling to wait. Returning animates the existing navigation state; it never alters or deletes messages.
- On iOS 26+, use native hosted floating bars registered through UIScrollEdgeElementContainerInteraction and soft scroll-edge effects, consistent with the message list's system chrome. The UIKit timeline fills the container and uses measured content insets to protect text under the bars. Earlier systems retain the masked blur fallback.
- Respect Reduce Motion when initiating transitions. Call, connection and SMS submission logic are unchanged by this follow-up.

Validation:
- Signed iOS Debug build passed: `/tmp/airsim-sms-native-toolbar-build.log`.
- Targeted UI regressions passed: 2 tests, 0 failures, including left swipe, keyboard/back and repeated list/thread/tab navigation. Log: `/tmp/airsim-sms-native-toolbar-test.log`. Screenshot inspection confirmed gradual native blur at the composer and a fully visible return badge.
- Installed the signed Debug 190 package on iPhone Air, preserving existing app data; device installation succeeded (database sequence 4624).

## Native scroll-edge boundary correction

The conversation's UIKit scrolling surface still began below the navigation bar,
so the soft edge effect was clipped at that boundary. Extend only the timeline
through the vertical container safe areas; keep the hosted header/composer inside
the safe area and preserve keyboard avoidance. No messaging or connection behavior
changes. The earlier-system fallback is unchanged.

Reference: https://developer.apple.com/videos/play/wwdc2025/284/ — scroll content
should extend beneath native bars; custom overlay containers register with the
scroll edge interaction. Applied apple-design-os and swiftui-liquid-glass guidance.

Validation:
- Added a simulator-only long-message fixture; assert the timeline reaches both
  screen edges, then inspect a mid-conversation screenshot with content beneath
  both bars. The navigation-bar hard seam is gone; bottom text blurs continuously
  behind the composer and through the home-indicator area.
- Two UI tests passed, including keyboard/back, horizontal swipe return and
  repeated tab/thread navigation: `/tmp/airsim-sms-boundaries-test.log`.
- Screenshot: `/tmp/airsim-sms-boundaries-attachments/1607AE6A-2402-4A32-9F2B-B072F8CF4F74.png`.
- Signed device build passed: `/tmp/airsim-sms-boundaries-build.log`.
- Initial device-build log creation failed when disk space was exhausted; retried
  once space became available. The final build and test results above passed.
- Installed on iPhone Air without uninstalling or clearing data; device installation succeeded (database sequence 4632).
