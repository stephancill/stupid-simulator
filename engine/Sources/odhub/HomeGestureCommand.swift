import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct HomeSwipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "home-swipe",
        abstract: "Swipe up from the bottom edge to go home, for devices without a Home button."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Option(help: "Milliseconds between each point of the swipe.")
    var stepMilliseconds: Int = 10

    @OptionGroup var verification: Verification

    func run() async throws {
        try await verification.check(udid) { try await send() }
    }

    private func send() async throws {
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        let session = try adapter.openInput(udid)
        defer { session.close() }

        try await SystemGesture.home(on: session, stepMilliseconds: stepMilliseconds)
        print("swiped up from the bottom edge")
    }
}
