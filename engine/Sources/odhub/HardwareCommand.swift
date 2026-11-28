import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Button: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "button",
        abstract: "Press a hardware button on a booted simulator."
    )

    enum Name: String, CaseIterable, ExpressibleByArgument {
        case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
        case softwareKeyboard = "software-keyboard"
        case playPause = "play-pause"

        var hardware: HardwareButton {
            switch self {
            case .home: .home
            case .lock: .lock
            case .volumeUp: .volumeUp
            case .volumeDown: .volumeDown
            case .siri: .siri
            case .softwareKeyboard: .softwareKeyboard
            case .playPause: .playPause
            }
        }
    }

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "Which button: home, lock, volume-up, volume-down, siri, software-keyboard (toggles the on-screen keyboard) or play-pause (Apple TV). An Apple TV has only home and play-pause; see `stupidsim remote`.")
    var button: Name

    @Option(help: "Milliseconds to hold the button down.")
    var holdMilliseconds: Int = 15

    @OptionGroup var verification: Verification

    func run() async throws {
        // Home pressed just after a rotation went home, but SpringBoard started the transition over 3 s
        // after the press, so the default wait reported no change for 2 presses in 5 (Safari, 4-vCPU
        // cloud session, x86Sim 0.7.4, iOS 27.2); right after an ordinary app it took about 1.4 s. Home
        // always changes the screen when it acts, and the wait ends at the first change, so a longer
        // one costs only a failure's time.
        try await verification.check(udid, defaultTimeout: button == .home ? 10 : 3) { try await press() }
    }

    private func press() async throws {
        let host = try SimulatorHosts.current()
        let session = try host.openInput(udid)
        defer { session.close() }

        try await session.button(button.hardware, phase: .down)
        try await Task.sleep(for: .milliseconds(holdMilliseconds))
        try await session.button(button.hardware, phase: .up)
        print("pressed \(button.rawValue)")
    }
}

struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate",
        abstract: "Turn a booted simulator to an orientation."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "portrait, portraitUpsideDown, landscapeLeft or landscapeRight.")
    var orientation: String

    @OptionGroup var verification: Verification

    func run() async throws {
        try await verification.check(udid) { try turn() }
    }

    private func turn() throws {
        guard let value = DeviceOrientation(rawValue: orientation) else {
            throw ValidationError("Unknown orientation. Use one of: \(DeviceOrientation.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let host = try SimulatorHosts.current()
        try host.setOrientation(value, udid: udid)
        print("rotated to \(value.rawValue)")
    }
}
