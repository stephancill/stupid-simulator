import Foundation

public enum RuntimeIdentifier {
    private static let prefix = "com.apple.CoreSimulator.SimRuntime."

    /// An Apple TV, whose input, display and accessibility differ from a phone's; see
    /// `IndigoHID.TV`.
    public static func isTV(_ identifier: String) -> Bool {
        identifier.hasPrefix("\(prefix)tvOS-")
    }

    /// Turns `com.apple.CoreSimulator.SimRuntime.iOS-17-5` into `iOS 17.5`. Used when the runtime
    /// itself is not installed, so neither CoreSimulator nor simctl can supply its real name.
    public static func readableName(for identifier: String) -> String {
        let trimmed = identifier.hasPrefix(prefix)
            ? String(identifier.dropFirst(prefix.count))
            : identifier
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return trimmed
        }
        return "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
    }
}
