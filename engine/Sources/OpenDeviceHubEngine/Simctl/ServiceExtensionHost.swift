import CryptoKit
import Foundation

/// What an app's Notification Service Extension made of a push.
public struct ServicedContent: Codable, Sendable, Hashable {
    public struct Attachment: Codable, Sendable, Hashable {
        public var identifier: String
        public var url: String
        public var type: String?
    }

    public var title: String
    public var subtitle: String
    public var body: String
    public var badge: Int?
    public var categoryIdentifier: String
    public var threadIdentifier: String
    public var targetContentIdentifier: String?
    /// `UNNotificationInterruptionLevel`'s raw value.
    public var interruptionLevel: Int
    public var relevanceScore: Double
    /// The extension's `userInfo`, keeping only what JSON can carry.
    public var userInfo: [String: JSONValue]
    public var attachments: [Attachment]
    /// Whether the extension made it a Communication Notification (`content.updating(from:)` with an
    /// `INSendMessageIntent`), which shows the sender's avatar on a device.
    public var isCommunication: Bool

    /// The APNs payload `simctl push` delivers in its place. simctl only takes JSON, so attachments
    /// and a communication avatar cannot be shown; `original` supplies what the content does not carry
    /// back, such as the sound.
    public func payload(replacing original: [String: Any]) -> [String: Any] {
        var payload: [String: Any] = userInfo.mapValues(\.object)
        var aps = original["aps"] as? [String: Any] ?? [:]
        aps.removeValue(forKey: "mutable-content")
        var alert: [String: Any] = [:]
        if !title.isEmpty { alert["title"] = title }
        if !subtitle.isEmpty { alert["subtitle"] = subtitle }
        if !body.isEmpty { alert["body"] = body }
        aps["alert"] = alert
        if let badge { aps["badge"] = badge } else { aps.removeValue(forKey: "badge") }
        if categoryIdentifier.isEmpty { aps.removeValue(forKey: "category") } else { aps["category"] = categoryIdentifier }
        if threadIdentifier.isEmpty { aps.removeValue(forKey: "thread-id") } else { aps["thread-id"] = threadIdentifier }
        if let targetContentIdentifier { aps["target-content-id"] = targetContentIdentifier }
        if let level = Self.interruptionLevels[interruptionLevel] { aps["interruption-level"] = level }
        if relevanceScore != 0 { aps["relevance-score"] = relevanceScore }
        payload["aps"] = aps
        return payload
    }

    static let interruptionLevels = [0: "passive", 1: "active", 2: "time-sensitive", 3: "critical"]
}

/// A JSON value, so `userInfo` survives a round trip through Codable.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// For JSONSerialization.
    public var object: Any {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .bool(let value): value
        case .array(let value): value.map(\.object)
        case .object(let value): value.mapValues(\.object)
        case .null: NSNull()
        }
    }
}

/// Runs an app's Notification Service Extension on a simulator, which `simctl push` never does: it
/// hands SpringBoard a finished notification request, skipping the remote-notification path where
/// the extension runs.
///
/// A small helper, compiled for the simulator on first use and run with `simctl spawn`, becomes the
/// extension's host the way usernotificationsd is: `+[NSExtension extensionWithIdentifier:error:]`,
/// a request, then `didReceiveNotificationRequest:withCompletionHandler:` on the extension's
/// `_UNNotificationServiceExtensionRemoteXPCInterface`, with the request built by
/// `+[UNNotificationRequest requestWithIdentifier:pushPayload:bundleIdentifier:]`, the system's own
/// conversion from an APNs payload. After 25 seconds it sends `serviceExtensionTimeWillExpire` and
/// waits 5 more, as the system does at 30.
///
/// The serviced notification cannot be posted as the app: that needs
/// `com.apple.private.usernotifications.notification-simulator`, and the simulator refuses to spawn an
/// ad-hoc binary carrying it (SimXPCErrorDomain 163). So it goes back through `simctl push` as JSON.
///
/// Verified on Xcode 27 (27A266a) with an iOS 27.0 device.
public enum ServiceExtensionHost {
    static let extensionPoint = "com.apple.usernotifications.service"

    /// The bundle identifier of the app's service extension, or nil when it has none.
    public static func extensionIdentifier(appBundleID: String, udid: String) throws -> String? {
        guard let app = try SimctlService().appContainer(udid: udid, bundleID: appBundleID, kind: .app) else {
            return nil
        }
        let plugins = app.appending(path: "PlugIns")
        let appexes = (try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? []
        for appex in appexes where appex.pathExtension == "appex" {
            guard let info = NSDictionary(contentsOf: appex.appending(path: "Info.plist")) as? [String: Any],
                  let point = (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String,
                  point == extensionPoint else { continue }
            return info["CFBundleIdentifier"] as? String
        }
        return nil
    }

    /// Runs the extension on `payload` and returns what it produced.
    public static func service(
        payload: Data,
        appBundleID: String,
        extensionID: String,
        udid: String
    ) throws -> ServicedContent {
        let helper = try helperExecutable()
        let input = FileManager.default.temporaryDirectory.appending(path: "\(Brand.commandName)-push-\(UUID().uuidString).json")
        try payload.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }

        let arguments = ["simctl", "spawn", udid, helper.path(percentEncoded: false), extensionID, appBundleID,
                         input.path(percentEncoded: false)]
        let result = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        guard result.status == 0 else {
            throw EngineError.privateCall(
                symbol: "NSExtension (\(extensionID))",
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        do {
            return try JSONDecoder().decode(ServicedContent.self, from: Data(result.standardOutput.utf8))
        } catch {
            throw EngineError.privateCall(symbol: "NSExtension (\(extensionID))", message: "unreadable result: \(error)")
        }
    }

    /// Compiled with the active Xcode's simulator SDK into the caches directory, keyed by the source
    /// and the SDK, so an Xcode update rebuilds it. Shipping it prebuilt would put an iOS binary inside
    /// the notarized Mac app.
    static func helperExecutable() throws -> URL {
        let sdk = try run(["--sdk", "iphonesimulator", "--show-sdk-path"])
        let sdkVersion = try run(["--sdk", "iphonesimulator", "--show-sdk-version"])
        let key = SHA256.hash(data: Data((helperSource + sdk + sdkVersion).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Brand.bundleIdentifier)
            .appending(path: "service-extension-host")
            .appending(path: key)
        let executable = directory.appending(path: "service-extension-host")
        if FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) {
            return executable
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "host.m")
        try Data(helperSource.utf8).write(to: source)
        let staging = directory.appending(path: "service-extension-host.\(UUID().uuidString)")
        _ = try run([
            "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-isysroot", sdk,
            "-target", "arm64-apple-ios\(sdkVersion)-simulator",
            source.path(percentEncoded: false), "-framework", "Foundation", "-framework", "UserNotifications",
            "-o", staging.path(percentEncoded: false),
        ])
        _ = try ProcessRunner.run("/usr/bin/codesign", ["-s", "-", "-f", staging.path(percentEncoded: false)])
        // Renamed into place, so a concurrent run never executes a half-written file.
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: staging, to: executable)
        return executable
    }

    private static func run(_ arguments: [String]) throws -> String {
        let result = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        guard result.status == 0 else {
            throw EngineError.capabilityUnavailable(
                name: "the simulator SDK to build the service extension host (xcrun \(arguments.joined(separator: " ")): \(result.standardError))"
            )
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let helperSource = #"""
        // Built by stupidsim. Hosts an app's Notification Service Extension for one push and prints
        // what it produced as JSON. Usage: service-extension-host <extension id> <app id> <payload.json>
        #import <Foundation/Foundation.h>
        #import <UserNotifications/UserNotifications.h>

        @interface NSExtension : NSObject
        + (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
        - (NSUUID *)beginExtensionRequestWithInputItems:(NSArray *)items error:(NSError **)error;
        - (id)_extensionContextForUUID:(NSUUID *)uuid;
        - (void)cancelExtensionRequestWithIdentifier:(NSUUID *)uuid;
        @end

        @interface UNNotificationRequest (Private)
        + (instancetype)requestWithIdentifier:(NSString *)identifier pushPayload:(NSDictionary *)payload bundleIdentifier:(NSString *)bundle;
        @end

        @protocol StupidsimServiceExtension
        - (void)didReceiveNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(UNNotificationContent *))handler;
        - (void)serviceExtensionTimeWillExpire;
        @end

        static int fail(int code, NSString *message) {
            fprintf(stderr, "%s\n", message.UTF8String);
            return code;
        }

        static id jsonSafe(id value) {
            if ([value isKindOfClass:NSDictionary.class]) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                for (id key in value) {
                    id safe = jsonSafe(value[key]);
                    if ([key isKindOfClass:NSString.class] && safe) out[key] = safe;
                }
                return out;
            }
            if ([value isKindOfClass:NSArray.class]) {
                NSMutableArray *out = [NSMutableArray array];
                for (id item in value) { id safe = jsonSafe(item); if (safe) [out addObject:safe]; }
                return out;
            }
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || value == NSNull.null) return value;
            return nil;
        }

        int main(int argc, char **argv) { @autoreleasepool {
            if (argc != 4) return fail(64, @"usage: service-extension-host <extension id> <app id> <payload.json>");
            NSString *extensionID = @(argv[1]), *appID = @(argv[2]);
            NSData *data = [NSData dataWithContentsOfFile:@(argv[3])];
            NSDictionary *payload = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![payload isKindOfClass:NSDictionary.class]) return fail(65, @"the payload is not a JSON object");

            NSError *error = nil;
            NSExtension *extension = [NSExtension extensionWithIdentifier:extensionID error:&error];
            if (!extension) return fail(69, [NSString stringWithFormat:@"no extension %@: %@", extensionID, error]);
            NSUUID *requestID = [extension beginExtensionRequestWithInputItems:@[] error:&error];
            if (!requestID) return fail(69, [NSString stringWithFormat:@"the extension did not start: %@", error]);
            id context = [extension _extensionContextForUUID:requestID];
            if (![context respondsToSelector:@selector(_auxiliaryConnection)]) return fail(69, @"the extension context has no connection");
            NSXPCConnection *connection = [context performSelector:@selector(_auxiliaryConnection)];

            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block UNNotificationContent *result = nil;
            __block NSError *connectionError = nil;
            id<StupidsimServiceExtension> proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
                connectionError = e;
                dispatch_semaphore_signal(done);
            }];
            UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString pushPayload:payload bundleIdentifier:appID];
            if (!request) return fail(65, @"the payload did not make a notification request");
            [proxy didReceiveNotificationRequest:request withCompletionHandler:^(UNNotificationContent *content) {
                result = content;
                dispatch_semaphore_signal(done);
            }];
            if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC))) {
                fprintf(stderr, "the extension took 25 s; sending serviceExtensionTimeWillExpire\n");
                [proxy serviceExtensionTimeWillExpire];
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
                    [extension cancelExtensionRequestWithIdentifier:requestID];
                    return fail(75, @"the extension did not call its content handler within 30 s");
                }
            }
            [extension cancelExtensionRequestWithIdentifier:requestID];
            if (!result) return fail(70, [NSString stringWithFormat:@"the extension's connection failed: %@", connectionError]);

            NSMutableArray *attachments = [NSMutableArray array];
            for (UNNotificationAttachment *attachment in result.attachments) {
                NSMutableDictionary *entry = [@{@"identifier": attachment.identifier ?: @"", @"url": attachment.URL.absoluteString ?: @""} mutableCopy];
                if (attachment.type) entry[@"type"] = attachment.type;
                [attachments addObject:entry];
            }
            BOOL communication = [result respondsToSelector:@selector(communicationContext)]
                && [result performSelector:@selector(communicationContext)] != nil;
            NSMutableDictionary *output = [@{
                @"title": result.title ?: @"", @"subtitle": result.subtitle ?: @"", @"body": result.body ?: @"",
                @"categoryIdentifier": result.categoryIdentifier ?: @"", @"threadIdentifier": result.threadIdentifier ?: @"",
                @"interruptionLevel": @(result.interruptionLevel), @"relevanceScore": @(result.relevanceScore),
                @"userInfo": jsonSafe(result.userInfo) ?: @{}, @"attachments": attachments, @"isCommunication": @(communication),
            } mutableCopy];
            if (result.badge) output[@"badge"] = result.badge;
            if (result.targetContentIdentifier) output[@"targetContentIdentifier"] = result.targetContentIdentifier;
            NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:&error];
            if (!json) return fail(70, [NSString stringWithFormat:@"could not encode the result: %@", error]);
            fwrite(json.bytes, 1, json.length, stdout);
        } return 0; }
        """#
}
