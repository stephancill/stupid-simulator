import ArgumentParser
import CoreGraphics
import Foundation
import OpenDeviceHubEngine

struct NotificationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notification",
        abstract: "Read or act on the notification banner a booted simulator is showing.",
        discussion: """
            Waits for a banner, optionally one whose text contains every --match, then:
            show     prints the banner's text (the app, when, title, subtitle and body)
            open     taps it, which opens the app and runs its notification response
            expand   opens the expanded notification with its actions, such as a text reply
            dismiss  dismisses it
            reply    expands it, types the text into its reply field and taps the field's button,
                     for a category whose only action is a UNTextInputNotificationAction
            The banner is found by what it says, not where or when it is, so acting on it straight
            after `stupidsim push` does not depend on timing. Notification Center and the lock screen
            are in `stupidsim ui-tree <udid> --springboard`.
            """
    )

    enum Action: String, ExpressibleByArgument, CaseIterable {
        case show, open, expand, dismiss, reply
    }

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "What to do: show, open, expand, dismiss or reply.")
    var action: Action = .show

    @Argument(help: "The text to send with reply.")
    var text: String?

    @Option(help: "Text the banner must contain, ignoring case. Repeat for several.")
    var match: [String] = []

    @Option(help: "Seconds to wait for a matching banner.")
    var timeout: Double = 5

    @Flag(help: "Print the banner as JSON, frames in points.")
    var json = false

    func validate() throws {
        guard timeout > 0 else { throw ValidationError("--timeout must be more than zero.") }
        if action == .reply, text?.isEmpty ?? true {
            throw ValidationError("reply needs the text to send.")
        }
        if action != .reply, text != nil {
            throw ValidationError("Only reply takes text.")
        }
    }

    func run() async throws {
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        let banner = try await BannerWatch.wait(adapter: adapter, udid: udid, matching: match, timeout: timeout)

        switch action {
        case .show:
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(banner), as: UTF8.self))
            } else {
                print(banner.label)
            }
            return
        case .open:
            try await tap(banner, adapter: adapter)
        case .expand:
            try adapter.performBannerAction(.more, udid: udid)
        case .dismiss:
            try adapter.performBannerAction(.dismiss, udid: udid)
        case .reply:
            try adapter.performBannerAction(.more, udid: udid)
            try await ReplyBar.send(text ?? "", adapter: adapter, udid: udid)
            print("replied to: \(banner.label)")
            return
        }
        // Each action takes the banner off screen, so one still there means the guest ignored it.
        try await BannerWatch.waitUntilGone(banner, adapter: adapter, udid: udid, timeout: 2)
        print("\(action.rawValue): \(banner.label)")
    }

    /// The banner's own Open accessibility action is not offered, and pressing it does nothing on
    /// Xcode 27 (27A266a), so opening is a real tap on its centre.
    private func tap(_ banner: NotificationBanner, adapter: any SimulatorAdapter) async throws {
        let orientation = try await DeviceOrientation.current(adapter, udid: udid)
        guard let point = banner.normalizedCenter(orientation: orientation) else {
            throw EngineError.capabilityUnavailable(name: "the banner's position on screen")
        }
        try await ReplyBar.tap(point, adapter: adapter, udid: udid)
    }
}

/// The reply field and its button that InputUI draws over an expanded notification. Neither is in
/// any app's tree, SpringBoard's included, so both are found by hit testing. Verified on Xcode 27
/// (27A266a) with an iOS 27.0 device: a TextArea across most of the bar and a Button at its right
/// end titled with the action's textInputButtonTitle.
enum ReplyBar {
    static let fieldRoles: Set<String> = ["AXTextArea", "AXTextField"]

    static func send(_ text: String, adapter: any SimulatorAdapter, udid: String) async throws {
        let orientation = try await DeviceOrientation.current(adapter, udid: udid)
        let field = try await findField(adapter: adapter, udid: udid, timeout: 3)
        let session = try adapter.openInput(udid)
        defer { session.close() }
        _ = try await Type.type(text, session: session, keyMilliseconds: 25)

        guard let button = try findButton(beside: field, adapter: adapter, udid: udid),
              let point = button.normalizedCenter(orientation: orientation) else {
            throw EngineError.capabilityUnavailable(name: "the reply field's send button")
        }
        try await tap(point, adapter: adapter, udid: udid)

        // Sending closes the bar, so a field still there means the tap did not send.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try await Task.sleep(for: .milliseconds(150))
            if try fieldShown(at: field, adapter: adapter, udid: udid) == false { return }
        } while Date() < deadline
        throw ReplyNotSent()
    }

    static func tap(_ point: CGPoint, adapter: any SimulatorAdapter, udid: String) async throws {
        let session = try adapter.openInput(udid)
        defer { session.close() }
        try await session.touch(TouchEvent(phase: .began, points: [point]))
        try await Task.sleep(for: .milliseconds(90))
        try await session.touch(TouchEvent(phase: .ended, points: [point]))
    }

    /// Scans up from the bottom of the screen, where the bar sits above the keyboard, in the
    /// guest's rotated coordinates.
    private static func findField(adapter: any SimulatorAdapter, udid: String, timeout: Double) async throws -> CGPoint {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for y in stride(from: 0.98, through: 0.3, by: -0.02) {
                let point = CGPoint(x: 0.3, y: y)
                if try fieldShown(at: point, adapter: adapter, udid: udid) { return point }
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        throw EngineError.capabilityUnavailable(
            name: "a reply field after expanding the notification. Its category may offer buttons rather than a text input; expand it and look with `stupidsim ui-tree <udid> --at x,y`"
        )
    }

    private static func fieldShown(at shown: CGPoint, adapter: any SimulatorAdapter, udid: String) throws -> Bool {
        guard let role = try adapter.accessibilityElement(udid, at: shown)?.element.role else { return false }
        return fieldRoles.contains(role)
    }

    /// The first button found walking left from the right edge, along the field's row.
    private static func findButton(beside field: CGPoint, adapter: any SimulatorAdapter, udid: String) throws -> AccessibilityHit? {
        for x in stride(from: 0.97, through: 0.5, by: -0.03) {
            if let hit = try adapter.accessibilityElement(udid, at: CGPoint(x: x, y: field.y)),
               hit.element.role == "AXButton" {
                return hit
            }
        }
        return nil
    }
}

struct ReplyNotSent: Error, CustomStringConvertible {
    var description: String {
        "The reply field was still showing after its button was tapped, so the reply may not have been sent."
    }
}

/// Polls SpringBoard for banners. Shared with `push --verify`.
enum BannerWatch {
    static let interval: Duration = .milliseconds(150)

    static func wait(
        adapter: any SimulatorAdapter,
        udid: String,
        matching expected: [String],
        timeout: Double
    ) async throws -> NotificationBanner {
        let deadline = Date().addingTimeInterval(timeout)
        var last: NotificationBanner?
        repeat {
            if let banner = try adapter.notificationBanner(udid) {
                last = banner
                if banner.contains(expected) { return banner }
            }
            try await Task.sleep(for: interval)
        } while Date() < deadline
        throw BannerNotFound(expected: expected, timeout: timeout, showing: last)
    }

    static func waitUntilGone(
        _ banner: NotificationBanner,
        adapter: any SimulatorAdapter,
        udid: String,
        timeout: Double
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard let current = try adapter.notificationBanner(udid), current.label == banner.label else { return }
            try await Task.sleep(for: interval)
        } while Date() < deadline
        throw BannerStillShowing(label: banner.label)
    }
}

struct BannerNotFound: Error, CustomStringConvertible {
    let expected: [String]
    let timeout: Double
    let showing: NotificationBanner?

    var description: String {
        let wanted = expected.isEmpty ? "a notification banner" : "a banner containing " + expected.map { "\"\($0)\"" }.joined(separator: " and ")
        guard let showing else { return "No banner appeared within \(timeout) s; wanted \(wanted)." }
        return "Wanted \(wanted) within \(timeout) s, but the banner says: \(showing.label)"
    }
}

struct BannerStillShowing: Error, CustomStringConvertible {
    let label: String

    var description: String {
        "The banner was still showing afterwards, so the device may not have acted on it: \(label)"
    }
}
