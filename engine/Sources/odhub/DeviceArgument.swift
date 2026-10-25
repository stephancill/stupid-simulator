import ArgumentParser
import OpenDeviceHubEngine

/// Lets every command that takes a UDID take `booted` instead, meaning the one booted simulator.
enum DeviceArgument {
    static let booted = "booted"

    static func resolve(_ argument: String) throws -> String {
        guard argument == booted else { return argument }
        let running = try AdapterFactory.make(for: XcodeLocator.locate()).devices().filter { $0.state == .booted }
        switch running.count {
        case 1:
            return running[0].udid
        case 0:
            throw ValidationError("No simulator is booted.")
        default:
            let names = running.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
            throw ValidationError("\(running.count) simulators are booted, so pass a UDID: \(names).")
        }
    }

    static let help = "The UDID of the simulator, or `booted` for the only booted one."
}
