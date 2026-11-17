import ArgumentParser
import OpenDeviceHubEngine

@main
struct ODHub: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: Brand.commandName,
        abstract: "Inspect, view and drive iOS simulators from the active Xcode.",
        discussion: """
            Commands that act on one simulator take its UDID first. Leave it out to use \
            $\(DeviceArgumentNormalizer.environmentVariable), or else the only booted simulator; \
            `--udid <udid>` works too.
            """,
        version: Brand.version,
        subcommands: [Doctor.self, List.self, View.self, Tap.self, Swipe.self, Pinch.self, Type.self, Key.self, Push.self, NotificationCommand.self, Paste.self, Copy.self, Button.self, Rotate.self, HomeSwipe.self, AppSwitcher.self, UITree.self, Wait.self, Screenshot.self]
    )

    /// The subcommands whose first positional argument is one simulator.
    static let deviceCommands: Set<String> = Set(
        [Tap.self, Swipe.self, Pinch.self, Type.self, Key.self, Push.self, NotificationCommand.self, Paste.self, Copy.self, Button.self, Rotate.self, HomeSwipe.self, AppSwitcher.self, UITree.self, Wait.self, Screenshot.self]
            .map { ($0 as any ParsableCommand.Type).configuration.commandName ?? "" }
    )

    static func main() async {
        let arguments = DeviceArgumentNormalizer.normalize(
            Array(CommandLine.arguments.dropFirst()),
            deviceCommands: deviceCommands
        )
        await main(arguments)
    }
}
