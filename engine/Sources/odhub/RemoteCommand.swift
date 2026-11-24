import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Remote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Press Siri Remote buttons on a booted Apple TV simulator.",
        discussion: """
            Buttons are pressed in order, so a path through the interface is one command:
            stupidsim remote <udid> down down right select
            stupidsim remote <udid> menu --repeat 3
            up, down, left and right move focus as a swipe on the touch surface does, select clicks
            it, menu goes back, home is the TV button and play-pause toggles playback.
            Type into a focused text field with `stupidsim type`.
            """
    )

    enum Name: String, CaseIterable, ExpressibleByArgument {
        case up, down, left, right, select, menu, home
        case playPause = "play-pause"

        /// Focus, select and Menu are the arrow keys, Return and Escape, which is how tvOS reads a
        /// keyboard; see `IndigoHID.TV`.
        var keyUsage: UInt32? {
            switch self {
            case .up: KeyboardMap.usageByKeyName["up"]
            case .down: KeyboardMap.usageByKeyName["down"]
            case .left: KeyboardMap.usageByKeyName["left"]
            case .right: KeyboardMap.usageByKeyName["right"]
            case .select: KeyboardMap.usageByKeyName["return"]
            case .menu: KeyboardMap.usageByKeyName["escape"]
            case .home, .playPause: nil
            }
        }

        var hardware: HardwareButton? {
            switch self {
            case .home: .home
            case .playPause: .playPause
            default: nil
            }
        }
    }

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "Buttons to press: up, down, left, right, select, menu, home or play-pause.")
    var buttons: [Name]

    @Option(help: "How many times to press each button.")
    var `repeat`: Int = 1

    @Option(help: "Milliseconds to wait after each press, so focus animations settle.")
    var pressMilliseconds: Int = 250

    @OptionGroup var verification: Verification

    func validate() throws {
        guard `repeat` > 0 else { throw ValidationError("--repeat must be at least 1.") }
        guard !buttons.isEmpty else { throw ValidationError("Name at least one button.") }
    }

    func run() async throws {
        try await verification.check(udid) { try await press() }
    }

    private func press() async throws {
        let host = try SimulatorHosts.current()
        let session = try host.openInput(udid)
        defer { session.close() }

        for button in buttons {
            for _ in 0..<`repeat` {
                if let usage = button.keyUsage {
                    try await session.key(KeyEvent(phase: .down, usage: usage))
                    try await Task.sleep(for: .milliseconds(25))
                    try await session.key(KeyEvent(phase: .up, usage: usage))
                } else if let hardware = button.hardware {
                    try await session.button(hardware, phase: .down)
                    try await Task.sleep(for: .milliseconds(25))
                    try await session.button(hardware, phase: .up)
                }
                try await Task.sleep(for: .milliseconds(pressMilliseconds))
            }
        }
        print("pressed \(buttons.map(\.rawValue).joined(separator: " "))\(`repeat` > 1 ? " ×\(`repeat`)" : "")")
    }
}
