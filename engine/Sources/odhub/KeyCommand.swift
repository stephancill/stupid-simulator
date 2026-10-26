import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press keys by name on a booted simulator's hardware keyboard.",
        discussion: """
            Each key is a name or a single character, with modifiers joined by +, pressed in order:
            stupidsim key <udid> delete --repeat 5
            stupidsim key <udid> cmd+a delete
            Names: \(KeyboardMap.usageByKeyName.keys.sorted().joined(separator: ", ")).
            Modifiers: cmd, shift, ctrl, option.
            """
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "Keys or chords to press, such as delete, return, left or cmd+a.")
    var keys: [String]

    @Option(help: "How many times to press each key.")
    var `repeat`: Int = 1

    @Option(help: "Milliseconds between key presses.")
    var keyMilliseconds: Int = 25

    @OptionGroup var verification: Verification

    func validate() throws {
        guard `repeat` > 0 else { throw ValidationError("--repeat must be at least 1.") }
        guard !keys.isEmpty else { throw ValidationError("Name at least one key.") }
    }

    func run() async throws {
        let chords = try keys.map { name in
            guard let chord = KeyboardMap.chord(named: name) else {
                throw ValidationError("Unknown key \"\(name)\". Run 'stupidsim key --help' for the names.")
            }
            return chord
        }
        try await verification.check(udid) { try await press(chords) }
    }

    private func press(_ chords: [KeyboardMap.KeyChord]) async throws {
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        let session = try adapter.openInput(udid)
        defer { session.close() }

        for chord in chords {
            for _ in 0..<`repeat` {
                for modifier in chord.modifiers {
                    try await session.key(KeyEvent(phase: .down, usage: modifier))
                }
                try await session.key(KeyEvent(phase: .down, usage: chord.usage))
                try await Task.sleep(for: .milliseconds(keyMilliseconds))
                try await session.key(KeyEvent(phase: .up, usage: chord.usage))
                for modifier in chord.modifiers.reversed() {
                    try await session.key(KeyEvent(phase: .up, usage: modifier))
                }
                try await Task.sleep(for: .milliseconds(keyMilliseconds))
            }
        }
        print("pressed \(keys.joined(separator: " "))\(`repeat` > 1 ? " ×\(`repeat`)" : "")")
    }
}
