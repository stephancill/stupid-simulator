import ArgumentParser
import CoreGraphics
import Foundation
import OpenDeviceHubEngine

struct Tap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Send a single tap to a booted simulator, at a normalized coordinate or on an element.",
        discussion: """
            Name the element the way `ui-tree` prints it, such as `--label Save --role Button`, and \
            the tap waits for it to appear (up to --timeout) and lands on its centre. Or give \
            `--x 0.5 --y 0.9`, or `--at 0.5,0.9`.
            """
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Option(help: "Horizontal position, 0 at the left edge and 1 at the right.")
    var x: Double?

    @Option(help: "Vertical position, 0 at the top edge and 1 at the bottom.")
    var y: Double?

    @Option(help: ArgumentHelp("Both positions at once, as `ui-tree` prints them after @.", valueName: "x,y"), transform: UITree.point)
    var at: CGPoint?

    @OptionGroup(title: "Element") var element: ElementOptions

    @Option(help: "Seconds to wait for the element to appear, with --label, --id or --role.")
    var timeout: Double = 5

    @Option(help: "Milliseconds to hold the contact down. (default: 120, or 800 with --long)")
    var holdMilliseconds: Int?

    @Flag(help: "Hold long enough for a long press: context menus, editing the home screen.")
    var long = false

    /// A 90 ms tap missed small fields (Settings' and Safari's bottom search bars) on Xcode 27
    /// (27A266a); agents ended up passing 120 on most taps.
    static let defaultHoldMilliseconds = 120
    /// UIKit's context menu needs about 500 ms; agents used 700 to 1200.
    static let longHoldMilliseconds = 800

    func validate() throws {
        let ways = [x != nil || y != nil, at != nil, element.isSet].filter { $0 }.count
        guard ways == 1 else {
            throw ValidationError("Say where to tap with --x and --y, --at x,y, or --label/--id/--role, and only one of them.")
        }
        if x != nil || y != nil {
            guard let x, let y else { throw ValidationError("--x and --y go together.") }
            guard (0...1).contains(x), (0...1).contains(y) else {
                throw ValidationError("--x and --y are normalized and must be between 0 and 1.")
            }
        }
        if let holdMilliseconds, holdMilliseconds < 0 {
            throw ValidationError("--hold-milliseconds cannot be negative.")
        }
        if holdMilliseconds != nil, long {
            throw ValidationError("--long sets the hold; pass either it or --hold-milliseconds.")
        }
        guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
    }

    @OptionGroup var verification: Verification

    func run() async throws {
        let host = try SimulatorHosts.current()
        let point: CGPoint
        var description = ""
        if element.isSet {
            let match = try await element.find(host, udid: udid, timeout: timeout)
            // `find` only returns matches on screen.
            guard let center = match.center else { throw ValidationError("\(match.line) has no centre on screen.") }
            point = center
            description = " on \(match.line)"
        } else if let at {
            point = at
        } else {
            point = CGPoint(x: x ?? 0, y: y ?? 0)
        }
        try await verification.check(udid) { try await send(host, at: point, description: description) }
    }

    private func send(_ host: any SimulatorHost, at point: CGPoint, description: String) async throws {
        let session = try host.openInput(udid)
        defer { session.close() }

        let hold = holdMilliseconds ?? (long ? Self.longHoldMilliseconds : Self.defaultHoldMilliseconds)
        try await session.touch(TouchEvent(phase: .began, points: [point]))
        try await Task.sleep(for: .milliseconds(hold))
        try await session.touch(TouchEvent(phase: .ended, points: [point]))
        print(String(format: "tapped %.2f, %.2f", point.x, point.y) + description)
    }
}
