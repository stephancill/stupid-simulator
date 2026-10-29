import CoreGraphics
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications

/// The test host's Notification Service Extension. It prefixes the title, so a test can tell from the
/// banner alone that the extension ran, and replaces userInfo, as extensions that decrypt a payload
/// do, which drops the payload's own keys such as "Simulator Target Bundle".
///
/// A payload with a "communication" object makes it a Communication Notification, so `stupidsim
/// push` can be checked on avatars: {"sender": "Alice", "avatar": 120, "group": "Room",
/// "groupAvatar": 64}. "avatar" and "groupAvatar" are the sides of a generated square PNG, blue for
/// the sender and green for the group; leave one out for no image. "group" makes it a group
/// conversation; "others" is how many people besides the sender and me are in it (default 1).
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
        let communication = request.content.userInfo["communication"] as? [String: Any]
        content.userInfo = ["serviced": true]
        guard let communication else {
            contentHandler(content)
            return
        }
        do {
            contentHandler(try content.updating(from: Self.intent(communication)))
        } catch {
            content.body = "updating(from:) failed: \(error)"
            contentHandler(content)
        }
    }

    static func intent(_ communication: [String: Any]) -> INSendMessageIntent {
        let sender = person(
            communication["sender"] as? String ?? "Sender", isMe: false,
            image: (communication["avatar"] as? Int).flatMap { image(side: $0, green: false) }
        )
        var recipients = [person("Me", isMe: true, image: nil)]
        let group = communication["group"] as? String
        // A group conversation is one with more than one other person.
        if group != nil {
            for index in 0..<(communication["others"] as? Int ?? 1) {
                recipients.append(person("Other \(index + 1)", isMe: false, image: nil))
            }
        }
        let intent = INSendMessageIntent(
            recipients: recipients, outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: group.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: "test-conversation", serviceName: nil, sender: sender, attachments: nil
        )
        if let side = communication["groupAvatar"] as? Int, let groupImage = image(side: side, green: true) {
            intent.setImage(groupImage, forParameterNamed: \.speakableGroupName)
        }
        return intent
    }

    static func person(_ name: String, isMe: Bool, image: INImage?) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: name, type: .unknown), nameComponents: nil,
            displayName: name, image: image, contactIdentifier: nil, customIdentifier: name, isMe: isMe
        )
    }

    static func image(side: Int, green: Bool) -> INImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.2, green: green ? 0.8 : 0.5, blue: green ? 0.3 : 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cgImage = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return INImage(imageData: data as Data)
    }
}
