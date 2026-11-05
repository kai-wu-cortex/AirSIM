import UserNotifications

/// Replaces the Relay's placeholder ("AirSIM／新短信") for end-to-end encrypted SMS (issue #24) with
/// the decrypted sender and text, using the key the app keeps in the shared keychain group. Other
/// pushes pass through unchanged. The work is synchronous, so the content is always delivered
/// before the extension's time limit.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let outcome = E2ESMSPush.open(request.content.userInfo, store: KeychainE2EKeyStore.shared)
        if let notification = E2ESMSPush.notification(for: outcome) {
            content.title = notification.title
            if let subtitle = notification.subtitle { content.subtitle = subtitle }
            content.body = notification.body
            if let thread = notification.threadIdentifier { content.threadIdentifier = thread }
        }
        contentHandler(content)
    }
}
