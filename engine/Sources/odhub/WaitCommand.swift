import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until an element is on screen, or gone, instead of sleeping.",
        discussion: """
            Polls the accessibility tree and prints the matching `ui-tree` lines as soon as the \
            element is on screen. Exits 2 when the time runs out. A tree that cannot be read yet, \
            such as while an app launches, counts as not there.
            """
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @OptionGroup(title: "Element") var element: ElementOptions

    @Flag(help: "Wait for the element to leave the screen instead.")
    var gone = false

    @Option(help: "Seconds to wait.")
    var timeout: Double = 10

    static let timedOutExitCode: Int32 = 2

    func validate() throws {
        guard element.isSet else { throw ValidationError("Say what to wait for with --label, --id or --role.") }
        guard element.index == nil else { throw ValidationError("wait does not take --index.") }
        guard timeout >= 0 else { throw ValidationError("--timeout cannot be negative.") }
    }

    func run() async throws {
        let host = try SimulatorHosts.current()
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var last: ElementOptions.Snapshot?
        var readError: (any Error)?
        while true {
            do {
                let snapshot = try await element.snapshot(host, udid: udid)
                last = snapshot
                readError = nil
                let onScreen = snapshot.matches.filter { $0.center != nil }
                if gone, onScreen.isEmpty {
                    print(String(format: "gone after %.1f s", Date().timeIntervalSince(start)))
                    return
                }
                if !gone, !onScreen.isEmpty {
                    onScreen.forEach { print($0.line) }
                    return
                }
            } catch {
                // An unreadable tree is not proof that the element left.
                readError = error
            }
            guard Date() < deadline else { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        var message = gone
            ? "\(element.query.summary) was still on screen after \(timeout) s."
            : "Nothing matching \(element.query.summary) appeared within \(timeout) s."
        if let readError {
            message += " The last read failed: \(readError.localizedDescription)"
        } else if let last, !gone {
            let lines = last.labelledLines
            message += " On screen now:\n" + lines.prefix(25).map { "  " + $0 }.joined(separator: "\n")
            if lines.count > 25 { message += "\n  ... and \(lines.count - 25) more" }
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        throw ExitCode(Self.timedOutExitCode)
    }
}
