# SMS conversation navigation and edge treatment

- Fix: the custom back action now updates its owning navigation state. The iOS 17+ split view returns to the sidebar and clears `showingConversation`; the older navigation stack clears its destination binding. Previously `dismiss()` on a split-view detail did not select the sidebar.
- Presentation: native `UIVisualEffectView` with directional gradient masks at both edges; the masks do not receive touches. Reduce Transparency uses the system background instead of blur.
- Bottom composer is now an overlay. The timeline reserves its measured height as a bottom content inset, including changes caused by multiline drafts or SMS feedback. Existing scroll-anchor restoration handles inset changes. The keyboard safe area remains enabled.
- No changes to SMS delivery, connection routing, call control, or device protocol in this follow-up.

Validation:
- Signed iOS device Debug build passed (`/tmp/airsim-sms-back-blur-build.log`).
- Added a UI regression for repeated back navigation, including keyboard open and blur overlay hit testing. The targeted iPhone Air simulator test passed (1 test, 0 failures), covering normal back, back with keyboard open, reopening the thread and restored tab access. Log: `/tmp/airsim-sms-back-blur-ui-test.log`.
- No physical-device install or SMS transmission performed in this follow-up.
