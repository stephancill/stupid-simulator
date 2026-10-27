import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Send a simulated push notification to an app on a booted simulator.",
        discussion: """
            The payload is a JSON object with an "aps" key, 4096 bytes or less, read from a file, from
            standard input, or built from --title and --body:
            stupidsim push <udid> payload.apns
            stupidsim push <udid> --bundle-id com.example.App --title "Hello" --body "World"
            The app is --bundle-id, or the payload's "Simulator Target Bundle" key when that is
            omitted. Only ordinary app pushes are supported: not VoIP, complication or file provider.
            A push with nothing to show, such as a silent content-available push, is refused.
            With --verify a banner must appear, so a push the app in front chooses not to present
            fails it.
            """
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "A JSON payload file. Standard input is read when this and --title/--body are omitted.")
    var payload: String?

    @Option(help: "The bundle identifier of the app to notify.")
    var bundleID: String?

    @Option(help: "The alert title, building the payload instead of reading one.")
    var title: String?

    @Option(help: "The alert body, building the payload instead of reading one.")
    var body: String?

    @OptionGroup var verification: Verification

    func validate() throws {
        let builds = title != nil || body != nil
        if builds, payload != nil {
            throw ValidationError("Pass a payload file or --title/--body, not both.")
        }
        if builds, bundleID == nil {
            throw ValidationError("--title and --body need --bundle-id to say which app to notify.")
        }
    }

    func run() async throws {
        let json = try payloadJSON()
        let target = bundleID ?? "the payload's target bundle"
        try await verification.check(udid, advice: Self.unchangedAdvice) {
            do {
                try SimctlService().push(json, bundleID: bundleID, udid: udid)
            } catch EngineError.simctl(_, _, let stderr) where stderr.contains(Self.notAuthorized) {
                throw PushNotAuthorized(target: target)
            }
            print("sent a push to \(target)")
        }
    }

    /// What simctl says when the app is not installed. Verified on Xcode 27 (27A266a).
    static let notAuthorized = "Source is not authorized"

    private func payloadJSON() throws -> String {
        if title != nil || body != nil {
            return try Self.alertPayload(title: title, body: body)
        }
        if let payload {
            return try String(contentsOf: URL(fileURLWithPath: payload), encoding: .utf8)
        }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    static func alertPayload(title: String?, body: String?) throws -> String {
        var alert: [String: String] = [:]
        alert["title"] = title
        alert["body"] = body
        let data = try JSONSerialization.data(
            withJSONObject: ["aps": ["alert": alert]],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static let unchangedAdvice = """
        No banner appeared: check the app is allowed to send notifications and that, when it is in \
        front, it presents them.
        """
}

struct PushNotAuthorized: Error, CustomStringConvertible {
    let target: String

    var description: String {
        "The simulator would not take a push for \(target). Is the app installed on this simulator?"
    }
}
