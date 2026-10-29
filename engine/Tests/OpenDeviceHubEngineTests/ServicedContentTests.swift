import Foundation
import Testing
@testable import OpenDeviceHubEngine

struct ServicedContentTests {
    let serviced = ServicedContent(
        title: "Alice", subtitle: "General", body: "Hello", badge: 3,
        categoryIdentifier: "apron.message", threadIdentifier: "room-1", targetContentIdentifier: nil,
        interruptionLevel: 2, relevanceScore: 0,
        userInfo: ["room": .string("room-1"), "count": .number(2)],
        attachments: [], communication: nil
    )
    let original: [String: Any] = [
        "aps": ["alert": ["title": "New message"], "mutable-content": 1, "sound": "default", "thread-id": "old"],
        "webpush": "ciphertext",
    ]

    @Test func theAlertAndGroupingComeFromTheExtension() throws {
        let aps = try #require(serviced.payload(replacing: original)["aps"] as? [String: Any])
        let alert = try #require(aps["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Alice")
        #expect(alert["subtitle"] as? String == "General")
        #expect(alert["body"] as? String == "Hello")
        #expect(aps["badge"] as? Int == 3)
        #expect(aps["category"] as? String == "apron.message")
        #expect(aps["thread-id"] as? String == "room-1")
        #expect(aps["interruption-level"] as? String == "time-sensitive")
    }

    @Test func itIsNotServicedTwiceAndKeepsWhatContentCannotCarry() throws {
        let aps = try #require(serviced.payload(replacing: original)["aps"] as? [String: Any])
        #expect(aps["mutable-content"] == nil)
        #expect(aps["sound"] as? String == "default")
    }

    @Test func customKeysAreTheExtensionsUserInfo() {
        let payload = serviced.payload(replacing: original)
        #expect(payload["room"] as? String == "room-1")
        #expect(payload["count"] as? Int == 2)
        #expect(payload["webpush"] == nil)
    }

    @Test func itDecodesWhatTheHelperPrints() throws {
        let json = #"{"attachments":[{"identifier":"a","url":"file:///a.png","type":"public.png"}],"body":"b","categoryIdentifier":"","interruptionLevel":1,"communication":{"isGroup":false,"isSystemImage":false,"displayName":"Room","imageURL":"intents-remote-image-proxy:?proxyIdentifier=97A4D594.png&storageServiceIdentifier=com.apple.Intents.INImageServiceConnection"},"relevanceScore":0,"subtitle":"","threadIdentifier":"","title":"t","userInfo":{"nested":{"ok":true},"list":[1,"two",null]}}"#
        let decoded = try JSONDecoder().decode(ServicedContent.self, from: Data(json.utf8))
        #expect(decoded.attachments.first?.type == "public.png")
        #expect(decoded.communication?.displayName == "Room")
        #expect(decoded.communication?.imageName == nil)
        #expect(decoded.userInfo["nested"] == .object(["ok": .bool(true)]))
        #expect(decoded.userInfo["list"] == .array([.number(1), .string("two"), .null]))
    }

    @Test func theAvatarIsInTheDevicesIntentsImageStore() throws {
        let url = try #require(URL(string: "intents-remote-image-proxy:?proxyIdentifier=97A4D594.png&storageServiceIdentifier=com.apple.Intents.INImageServiceConnection"))
        let file = try Communication.file(for: url, udid: "UDID")
        #expect(file == SimctlService.deviceDataDirectory(udid: "UDID").appending(path: "Library/Intents/Images/97A4D594.png"))
    }

    @Test func anUnknownImageStoreFailsLoudly() throws {
        let other = try #require(URL(string: "intents-remote-image-proxy:?proxyIdentifier=../x.png&storageServiceIdentifier=com.apple.Intents.INImageServiceConnection"))
        #expect(throws: AvatarUnreadable.self) { try Communication.file(for: other, udid: "UDID") }
        let scheme = try #require(URL(string: "https://example.com/a.png"))
        #expect(throws: AvatarUnreadable.self) { try Communication.file(for: scheme, udid: "UDID") }
    }

    @Test func noCommunicationContextIsNoAvatar() throws {
        let communication = Communication(isGroup: true, displayName: "Room", imageURL: nil, imageName: nil, isSystemImage: false)
        #expect(try communication.avatar(udid: "UDID") == nil)
    }
}
