import Foundation

/// Rewrites a `stupidsim` command line so the simulator can be left out or named with `--udid`.
///
/// Every device command takes the simulator as its first positional argument, ahead of others such
/// as `type`'s text. Agents often wrote `--udid <udid>` or left it out, so before parsing the
/// device is moved to, or inserted at, that position: `--udid` first, then any UDID or `booted`
/// already present (left where it is), then `$STUPIDSIM_UDID`, then `booted`, which the command
/// resolves to the only booted simulator and fails on when there are none or several.
public enum DeviceArgumentNormalizer {
    public static let environmentVariable = "STUPIDSIM_UDID"

    public static func normalize(
        _ arguments: [String],
        deviceCommands: Set<String>,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard let command = arguments.first, deviceCommands.contains(command) else { return arguments }
        var rest = Array(arguments.dropFirst())
        let end = rest.firstIndex(of: "--") ?? rest.endIndex

        if let flag = rest[..<end].firstIndex(where: { $0 == "--udid" || $0.hasPrefix("--udid=") }) {
            let device: String
            if rest[flag] == "--udid" {
                // A missing value is left for the parser to report.
                guard flag + 1 < end else { return arguments }
                device = rest[flag + 1]
                rest.removeSubrange(flag...(flag + 1))
            } else {
                device = String(rest[flag].dropFirst("--udid=".count))
                rest.remove(at: flag)
            }
            return [command, device] + rest
        }
        if rest[..<end].contains(where: isDevice) { return arguments }
        let fallback = environment[environmentVariable].flatMap { $0.isEmpty ? nil : $0 } ?? "booted"
        return [command, fallback] + rest
    }

    /// A UDID or `booted`. Device names are not accepted anywhere, so nothing else can be one.
    public static func isDevice(_ argument: String) -> Bool {
        argument == "booted" || UUID(uuidString: argument) != nil
    }
}
