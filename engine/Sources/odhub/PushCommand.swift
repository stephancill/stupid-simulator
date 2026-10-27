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
            A Notification Service Extension does not run: the banner shows the payload as sent.
            --verify waits for a banner showing the alert's title, subtitle and body, or every
            --expect instead, and prints its text. A push the app in front chooses not to present
            fails it. Act on the banner with `stupidsim notification`.
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

    @Flag(help: "Fail unless a banner with the alert's text appears, and print the banner's text.")
    var verify = false

    @Option(help: "Text the banner must contain with --verify, ignoring case, in place of the alert's own. Repeat for several.")
    var expect: [String] = []

    @Option(help: "Seconds to wait for the banner with --verify.")
    var verifyTimeout: Double = 5

    func validate() throws {
        guard verifyTimeout > 0 else { throw ValidationError("--verify-timeout must be more than zero.") }
        if !expect.isEmpty, !verify {
            throw ValidationError("--expect needs --verify.")
        }
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
        do {
            try SimctlService().push(json, bundleID: bundleID, udid: udid)
        } catch EngineError.simctl(_, _, let stderr) where stderr.contains(Self.notAuthorized) {
            throw PushNotAuthorized(target: target)
        }
        print("sent a push to \(target)")
        guard verify else { return }
        // The command's own line comes before the verdict, even when stdout is a pipe.
        fflush(stdout)

        let expected = expect.isEmpty ? Self.alertText(inPayload: json) : expect
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        do {
            let banner = try await BannerWatch.wait(adapter: adapter, udid: udid, matching: expected, timeout: verifyTimeout)
            print("verified: \(banner.label)")
        } catch let error as BannerNotFound {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            if error.showing == nil {
                FileHandle.standardError.write(Data("\(Self.noBannerAdvice)\n".utf8))
            }
            throw ExitCode(Self.unverifiedExitCode)
        }
    }

    /// The same code `--verify` uses on the input commands for "the device did not act on it".
    static let unverifiedExitCode: Int32 = 2

    /// The alert's title, subtitle and body, which the banner shows unless something changed them.
    /// A payload that does not parse yields nothing, and simctl has already said why.
    static func alertText(inPayload json: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let aps = object["aps"] as? [String: Any] else { return [] }
        if let alert = aps["alert"] as? String { return [alert] }
        guard let alert = aps["alert"] as? [String: Any] else { return [] }
        return ["title", "subtitle", "body"].compactMap { alert[$0] as? String }.filter { !$0.isEmpty }
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

    static let noBannerAdvice = """
        Check the app is allowed to send notifications and that, when it is in front, it presents \
        them.
        """
}

struct PushNotAuthorized: Error, CustomStringConvertible {
    let target: String

    var description: String {
        "The simulator would not take a push for \(target). Is the app installed on this simulator?"
    }
}
