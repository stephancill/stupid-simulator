import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Paste: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Put text on a simulator's pasteboard, reading standard input when no text is given."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Argument(help: "The text to place. Standard input is used when this is omitted.")
    var text: String?

    func run() throws {
        let value: String
        if let text {
            value = text
        } else {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            value = String(decoding: data, as: UTF8.self)
        }
        let host = try SimulatorHosts.current()
        try host.setPasteboard(value, udid: udid)
        // Device Hub, and any viewer that keeps the pasteboards in step, writes the Mac's clipboard
        // over the device's straight away, so what was placed is read back rather than assumed.
        Thread.sleep(forTimeInterval: 0.25)
        guard try host.pasteboard(udid) == value else {
            throw PasteboardOverwritten()
        }
        print("copied \(value.count) characters to the device pasteboard")
    }
}

struct PasteboardOverwritten: Error, CustomStringConvertible {
    var description: String {
        """
        The device's pasteboard was overwritten straight after it was set. Device Hub, or a window \
        that keeps pasteboards in step with the Mac, is probably running.
        """
    }
}

struct Copy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Print a simulator's pasteboard contents."
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    func run() throws {
        print(try SimulatorHosts.current().pasteboard(udid), terminator: "")
    }
}
