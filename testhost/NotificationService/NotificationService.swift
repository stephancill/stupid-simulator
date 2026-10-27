import UserNotifications

/// The test host's Notification Service Extension. It prefixes the title, so a test can tell from the
/// banner alone that the extension ran.
@objc(NotificationService)
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        content.title = "Serviced: " + content.title
        content.userInfo["serviced"] = true
        contentHandler(content)
    }
}
