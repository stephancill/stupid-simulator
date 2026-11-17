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

    @Argument(help: "Where to write the PNG, the same as --output.")
    var path: String?

    @Option(name: [.short, .long], help: "Where to write the PNG. Defaults to a timestamped file in the current directory.")
    var output: String?

    func validate() throws {
        if path != nil, output != nil { throw ValidationError("Give the file once, as an argument or with --output.") }
    }

    func run() throws {
        let file = URL(fileURLWithPath: path ?? output ?? defaultName()).standardizedFileURL
        try SimulatorHosts.current().screenshot(udid).write(to: file)
        print(file.path)
    }

    private func defaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "screenshot-\(formatter.string(from: Date())).png"
    }
}
