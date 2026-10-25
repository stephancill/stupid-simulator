import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Save a booted simulator's screen as a PNG and print where it went."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Option(name: [.short, .long], help: "Where to write the PNG. Defaults to a timestamped file in the current directory.")
    var output: String?

    func run() throws {
        let file = URL(fileURLWithPath: output ?? defaultName()).standardizedFileURL
        try SimctlService().screenshot(udid: udid, to: file)
        print(file.path)
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).png"
    }
}
