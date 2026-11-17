import ArgumentParser
import CoreGraphics
import Foundation
import OpenDeviceHubEngine

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swipe",
        abstract: "Drag one finger across a booted simulator between normalized coordinates."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Option(help: "Where the drag starts, horizontally, 0 to 1.")
    var fromX: Double?

    @Option(help: "Where the drag starts, vertically, 0 to 1.")
    var fromY: Double?

    @Option(help: "Where the drag ends, horizontally, 0 to 1.")
    var toX: Double?

    @Option(help: "Where the drag ends, vertically, 0 to 1.")
    var toY: Double?

    @Option(help: ArgumentHelp("Where the drag starts, both positions at once, in place of --from-x and --from-y.", valueName: "x,y"), transform: UITree.point)
    var from: CGPoint?

    @Option(help: ArgumentHelp("Where the drag ends, both positions at once, in place of --to-x and --to-y.", valueName: "x,y"), transform: UITree.point)
    var to: CGPoint?

    private var start: CGPoint? {
        from ?? fromX.flatMap { x in fromY.map { CGPoint(x: x, y: $0) } }
    }

    private var end: CGPoint? {
        to ?? toX.flatMap { x in toY.map { CGPoint(x: x, y: $0) } }
    }

    @Option(help: "How many intermediate points to send.")
    var steps: Int = 16

    @Option(help: "Milliseconds between each point.")
    var stepMilliseconds: Int = 12

    func validate() throws {
        if from != nil, fromX != nil || fromY != nil {
            throw ValidationError("Pass --from or --from-x with --from-y, not both.")
        }
        if to != nil, toX != nil || toY != nil {
            throw ValidationError("Pass --to or --to-x with --to-y, not both.")
        }
        guard let start, let end else {
            throw ValidationError("Say where the drag starts and ends: --from x,y --to x,y, or --from-x, --from-y, --to-x and --to-y.")
        }
        for value in [start.x, start.y, end.x, end.y] where !(0...1).contains(value) {
            throw ValidationError("Coordinates are normalized and must be between 0 and 1.")
        }
        guard steps >= 1 else { throw ValidationError("--steps must be at least 1.") }
        guard stepMilliseconds >= 0 else { throw ValidationError("--step-milliseconds cannot be negative.") }
    }

    @OptionGroup var verification: Verification

    func run() async throws {
        try await verification.check(udid) { try await send() }
    }

    private func send() async throws {
        let host = try SimulatorHosts.current()
        let session = try host.openInput(udid)
        defer { session.close() }

        // validate() has checked both.
        guard let start, let end else { return }
        let path = TouchPath.points(from: start, to: end, steps: steps)
        try await session.touch(TouchEvent(phase: .began, points: [path[0]]))
        for point in path.dropFirst() {
            try await Task.sleep(for: .milliseconds(stepMilliseconds))
            try await session.touch(TouchEvent(phase: .moved, points: [point]))
        }
        try await session.touch(TouchEvent(phase: .ended, points: [path[path.count - 1]]))
        print("swiped \(start.x),\(start.y) to \(end.x),\(end.y) in \(path.count) points")
    }
}
