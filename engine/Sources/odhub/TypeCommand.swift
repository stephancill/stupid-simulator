import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Type: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text on a booted simulator using its hardware keyboard.",
        discussion: "Characters are typed as on a US keyboard, holding Shift for capitals and symbols."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "The text to type.")
    var text: String

    @Option(help: "Milliseconds between key presses.")
    var keyMilliseconds: Int = 25

    @OptionGroup var verification: Verification

    func run() async throws {
        try await verification.check(udid) { try await send() }
    }

    private func send() async throws {
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        let session = try adapter.openInput(udid)
        defer { session.close() }
        let count = try await Self.type(text, session: session, keyMilliseconds: keyMilliseconds)
        print("typed \(count) keys")
    }

    /// Shared with `notification reply`. Returns how many keys were pressed.
    static func type(_ text: String, session: any InputSession, keyMilliseconds: Int) async throws -> Int {
        guard let keys = KeyboardMap.keys(forTyping: text) else {
            throw ValidationError("That text contains a character with no key on a US keyboard.")
        }
        for key in keys {
            if key.shifted {
                try await session.key(KeyEvent(phase: .down, usage: KeyboardMap.leftShiftUsage))
            }
            try await session.key(KeyEvent(phase: .down, usage: key.usage))
            try await Task.sleep(for: .milliseconds(keyMilliseconds))
            try await session.key(KeyEvent(phase: .up, usage: key.usage))
            if key.shifted {
                try await session.key(KeyEvent(phase: .up, usage: KeyboardMap.leftShiftUsage))
            }
            try await Task.sleep(for: .milliseconds(keyMilliseconds))
        }
        return keys.count
    }
}
