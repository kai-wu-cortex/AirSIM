import UserNotifications

/// Replaces the Relay's placeholder ("AirSIM／新短信") for end-to-end encrypted SMS (issue #24) with
/// the decrypted sender and text, using the key the app keeps in the shared keychain group. Other
/// pushes pass through unchanged, except scoped missed-call alerts which replace
/// stale ringing/local notifications. Decryption remains synchronous.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        AirSIMHealthStore.received()
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if content.userInfo["event"] as? String == "call_owner",
           content.userInfo["notification_status"] as? String == "missed",
           let agent = content.userInfo["agent_id"] as? String, !agent.isEmpty,
           let call = content.userInfo["call_id"] as? String, !call.isEmpty {
            // Also reconcile when the host is suspended: a late APNs alert
            // replaces the local fallback and the ringing mirror, never SMS.
            let info = content.userInfo
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let stale = delivered.filter {
                    let old = $0.request.content.userInfo
                    guard ["AIRSIM_INCOMING_CALL", "AIRSIM_INCOMING_CALL_MIRROR", "AIRSIM_MISSED_CALL"]
                        .contains($0.request.content.categoryIdentifier),
                        old["agent_id"] as? String == agent, old["call_id"] as? String == call else { return false }
                    if let a = info["generation"] as? NSNumber, let b = old["generation"] as? NSNumber, a != b { return false }
                    if let a = info["call_uuid"] as? String, let b = old["call_uuid"] as? String, a != b { return false }
                    return true
                }.map { $0.request.identifier }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
                contentHandler(content)
            }
            return
        }
        let outcome = E2ESMSPush.open(request.content.userInfo, store: KeychainE2EKeyStore.shared)
        if let notification = E2ESMSPush.notification(for: outcome) {
            content.title = notification.title
            switch outcome {
            case .undecryptable, .locked, .unencryptedFromEncryptedAgent:
                if let agent = content.userInfo["agent_id"] as? String,
                   let name = AirSIMHealthStore.load().deviceNames?[agent] {
                    content.title = "AirSIM · " + name
                }
            default: break
            }
            if let subtitle = notification.subtitle { content.subtitle = subtitle }
            content.body = notification.body
            if let thread = notification.threadIdentifier { content.threadIdentifier = thread }
        }
        contentHandler(content)
    }
}
