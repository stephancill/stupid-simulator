import Foundation

/// One x86Sim device: a directory `var/device-a64[-<name>]` in x86Sim's data directory, holding
/// `name`, `model`, `runtime`, the `sim.env` its processes start with, and `data`, the device's
/// own file system. Layout read from x86Sim 0.3.0.
public struct X86SimDevice: Sendable, Hashable {
    public let directory: URL
    /// What `x86sim device create` was given, or the directory's suffix.
    public let name: String
    /// The model's marketing name, such as "iPhone 17 Pro".
    public let model: String
    /// The runtime directory's name, such as "ios-27.2-24B8117-arm64".
    public let runtime: String
    /// The UDID the guest sees as SIMULATOR_UDID, which is what stupidsim prints and takes.
    public let udid: String
    /// The screen in pixels and its scale, from the same environment.
    public let screenPixels: CGSize?
    public let scale: Double?

    /// The directory under x86Sim's data that holds devices, and the prefix every device's
    /// directory starts with.
    static let devicesPath = "var"
    static let directoryPrefix = "device-a64"

    public init(directory: URL) throws {
        self.directory = directory
        let environment = try Self.environment(in: directory)
        let suffix = Self.suffix(of: directory.lastPathComponent)
        name = Self.firstLine(directory.appending(path: "name")) ?? environment["SIMULATOR_DEVICE_NAME"] ?? suffix ?? "default"
        model = Self.firstLine(directory.appending(path: "model")) ?? "unknown model"
        runtime = Self.firstLine(directory.appending(path: "runtime")) ?? ""
        guard let udid = environment["SIMULATOR_UDID"], !udid.isEmpty else {
            throw X86SimError.deviceUnreadable(directory: directory.path, reason: "sim.env has no SIMULATOR_UDID")
        }
        self.udid = udid
        if let width = environment["SIMULATOR_MAINSCREEN_WIDTH"].flatMap(Double.init),
           let height = environment["SIMULATOR_MAINSCREEN_HEIGHT"].flatMap(Double.init) {
            screenPixels = CGSize(width: width, height: height)
        } else {
            screenPixels = nil
        }
        scale = environment["SIMULATOR_MAINSCREEN_SCALE"].flatMap(Double.init)
    }

    /// The device's own file system, which the guest sees as its home.
    public var dataDirectory: URL { directory.appending(path: "data") }

    /// simhid's socket: touches, keys and buttons go in as text lines.
    public var inputSocket: URL { dataDirectory.appending(path: "simhid.sock") }

    /// Where simhid writes the orientation the device ends up in.
    public var orientationFile: URL { dataDirectory.appending(path: "orientation") }

    /// The shared-memory ring simfb publishes every frame to. x86Sim's `config.sh` names it after the
    /// directory: `device-a64` gives `x86sim-a64-simfb.ring`, `device-a64-<name>` gives
    /// `x86sim-a64-<name>-simfb.ring`.
    public var frameRing: URL {
        let directoryName = directory.lastPathComponent
        let tail = directoryName.hasPrefix("device-") ? String(directoryName.dropFirst("device-".count)) : directoryName
        return URL(fileURLWithPath: "/dev/shm/x86sim-\(tail)-simfb.ring")
    }

    /// "iOS 27.2" from "ios-27.2-24B8117-arm64".
    public var runtimeName: String {
        let parts = runtime.split(separator: "-")
        guard parts.count >= 2 else { return runtime }
        let platform = switch parts[0].lowercased() {
        case "ios": "iOS"
        case "tvos": "tvOS"
        case "watchos": "watchOS"
        case "xros", "visionos": "visionOS"
        default: String(parts[0])
        }
        return "\(platform) \(parts[1])"
    }

    /// Whether the device is running: its input socket answers. A socket file left behind by a
    /// device that stopped refuses the connection.
    public var isBooted: Bool {
        (try? SimHIDConnection(socket: inputSocket))?.close() != nil
    }

    public func info() -> DeviceInfo {
        let runtimeParts = runtimeName.split(separator: " ")
        let runtimeIdentifier = runtimeParts.count == 2
            ? "com.apple.CoreSimulator.SimRuntime.\(runtimeParts[0])-\(runtimeParts[1].replacingOccurrences(of: ".", with: "-"))"
            : runtime
        return DeviceInfo(
            udid: udid,
            name: name,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.\(model.replacingOccurrences(of: " ", with: "-"))",
            runtimeIdentifier: runtimeIdentifier,
            runtimeName: runtimeName,
            state: isBooted ? .booted : .shutdown,
            isAvailable: true
        )
    }

    /// Every device under x86Sim's data directory, in name order. Directories that are not
    /// finished devices (no sim.env yet) are left out.
    public static func all(in dataRoot: URL) throws -> [X86SimDevice] {
        let parent = dataRoot.appending(path: devicesPath)
        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return try entries
            .filter { $0.lastPathComponent.hasPrefix(directoryPrefix) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "sim.env").path) }
            .map { try X86SimDevice(directory: $0) }
            .sorted { $0.name < $1.name }
    }

    /// The `KEY=value` lines of sim.env.
    static func environment(in directory: URL) throws -> [String: String] {
        let file = directory.appending(path: "sim.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw X86SimError.deviceUnreadable(directory: directory.path, reason: "no readable sim.env")
        }
        return parseEnvironment(text)
    }

    static func parseEnvironment(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }

    static func suffix(of directoryName: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard directoryName.hasPrefix(prefix) else { return nil }
        return String(directoryName.dropFirst(prefix.count))
    }

    private static func firstLine(_ file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}

public enum X86SimError: Error, LocalizedError, Sendable, Hashable {
    case notInstalled(searched: [String])
    case noDataDirectory(path: String)
    case deviceUnreadable(directory: String, reason: String)
    case deviceNotFound(argument: String, known: [String])
    case notBooted(name: String)
    case commandFailed(command: String, status: Int32, output: String)
    case guestMissing(searched: [String])
    case guest(command: String, message: String)
    case unsupported(what: String)
    /// Anything else, worded as a whole sentence.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let searched):
            return """
                x86Sim was not found. Install its AppImage from https://github.com/x86sim/x86sim/releases \
                and set STUPIDSIM_X86SIM to it. Looked in: \(searched.joined(separator: ", "))
                """
        case .noDataDirectory(let path):
            return "x86Sim has no data directory at \(path). Run x86Sim's setup first, or set X86SIM_DATA."
        case .deviceUnreadable(let directory, let reason):
            return "The x86Sim device at \(directory) could not be read: \(reason)."
        case .deviceNotFound(let argument, let known):
            let list = known.isEmpty ? "there are none; create one with `x86sim device create`" : known.joined(separator: ", ")
            return "No x86Sim device is called or has the UDID \(argument). Devices: \(list)."
        case .notBooted(let name):
            return "The x86Sim device \(name) is not running. Start it from x86Sim's launcher first."
        case .commandFailed(let command, let status, let output):
            return "\(command) failed with status \(status): \(output)"
        case .guestMissing(let searched):
            return """
                stupidsim-guest, the helper stupidsim runs inside the device, was not found. Set \
                STUPIDSIM_GUEST to it. Looked in: \(searched.joined(separator: ", "))
                """
        case .guest(let command, let message):
            return "stupidsim-guest \(command) failed: \(message)"
        case .unsupported(let what):
            return "\(what) is not available with x86Sim."
        case .failed(let message):
            return message
        }
    }
}
