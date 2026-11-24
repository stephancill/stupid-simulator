import CoreGraphics
import Foundation

/// stupidsim-guest, the small arm64 program stupidsim runs inside an x86Sim device for what can
/// only be read from inside it: the accessibility tree, hit testing, notification banners and the
/// pasteboard. Its source is guest/stupidsim-guest.m.
public struct GuestHelper: Sendable {
    public let program: URL
    let install: X86SimInstall
    /// Whether commands go to a server kept running in the device (the default) or each start the
    /// program anew, as before 0.8.5. `STUPIDSIM_GUEST_SERVER=0` chooses the latter.
    let useServer: Bool

    public static let programName = "stupidsim-guest"
    public static let programVariable = "STUPIDSIM_GUEST"
    public static let serverVariable = "STUPIDSIM_GUEST_SERVER"
    static let begin = "@@stupidsim-guest-begin@@"
    static let end = "@@stupidsim-guest-end@@"
    /// A tree read takes about a second under x86Sim on a desktop CPU; this leaves room for a
    /// device that is still starting.
    static let timeoutSeconds = 60

    public init(install: X86SimInstall, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let candidates = Self.candidates(environment: environment, executable: ExecutableLocator.runningExecutableURL())
        guard let program = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw X86SimError.guestMissing(searched: candidates.map(\.path))
        }
        self.program = program
        self.install = install
        useServer = environment[Self.serverVariable] != "0"
    }

    /// `$STUPIDSIM_GUEST`, else beside the stupidsim executable, else in `../libexec/stupidsim`
    /// as the Linux package lays it out.
    static func candidates(environment: [String: String], executable: URL?) -> [URL] {
        if let configured = environment[programVariable], !configured.isEmpty {
            return [URL(fileURLWithPath: configured)]
        }
        guard let directory = executable?.deletingLastPathComponent() else { return [] }
        return [
            directory.appending(path: programName),
            directory.deletingLastPathComponent().appending(path: "libexec/stupidsim/\(programName)"),
        ]
    }

    /// Runs one guest command in the device and returns the JSON it answered.
    func run(_ arguments: [String], device: X86SimDevice) throws -> Data {
        // The pasteboard is read by a program of its own. In the server, which has loaded AXRuntime
        // and turned on accessibility automation first, UIPasteboard set the text but read back an
        // empty string every time, while a fresh program read it (x86Sim 0.5.0, iOS 27.2).
        if useServer, !(arguments.first ?? "").hasPrefix("pasteboard-") {
            return try GuestServer(helper: self, device: device).request(arguments)
        }
        let output = try install.run(
            ["spawn", "--timeout", String(Self.timeoutSeconds), program.path] + arguments,
            device: device
        )
        return try Self.answer(in: output, command: arguments.first ?? "")
    }

    /// The JSON between the marker lines. x86Sim's spawn writes its own lines into the same output.
    static func answer(in output: String, command: String) throws -> Data {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == begin }),
              let finish = lines[start...].firstIndex(where: { $0 == end }) else {
            let tail = lines.suffix(5).joined(separator: "\n")
            throw X86SimError.guest(command: command, message: "it gave no answer. Its last lines: \(tail)")
        }
        let json = Data(lines[(start + 1)..<finish].joined(separator: "\n").utf8)
        if let failure = try? JSONDecoder().decode(Failure.self, from: json) {
            throw X86SimError.guest(command: command, message: failure.error)
        }
        return json
    }

    private struct Failure: Decodable {
        let error: String
    }

    // MARK: - Commands

    public func tree(springboard: Bool, device: X86SimDevice) throws -> AccessibilityElement {
        try treeAndPID(springboard: springboard, device: device).tree
    }

    /// The tree and the pid of its app, as the app sees itself (inside Darling's pid namespace).
    func treeAndPID(springboard: Bool, device: X86SimDevice) throws -> (tree: AccessibilityElement, pid: Int32?) {
        let json = try run(springboard ? ["tree", "--springboard"] : ["tree"], device: device)
        let tree = try JSONDecoder().decode(AccessibilityElement.self, from: json)
        return (tree, try? JSONDecoder().decode(Root.self, from: json).pid)
    }

    private struct Root: Decodable {
        let pid: Int32
    }

    public func element(at shown: CGPoint, device: X86SimDevice) throws -> AccessibilityHit? {
        let json = try run(["hit", String(format: "%.5f", Double(shown.x)), String(format: "%.5f", Double(shown.y))], device: device)
        let hit = try JSONDecoder().decode(Hit.self, from: json)
        return hit.element.map { AccessibilityHit(element: $0, screen: hit.screen) }
    }

    public func banner(device: X86SimDevice) throws -> NotificationBanner? {
        try JSONDecoder().decode(BannerAnswer.self, from: run(["banner"], device: device)).banner
    }

    public func pasteboard(device: X86SimDevice) throws -> String {
        try JSONDecoder().decode(Pasteboard.self, from: run(["pasteboard-get"], device: device)).text
    }

    /// Returns what the pasteboard holds afterwards.
    public func setPasteboard(_ text: String, device: X86SimDevice) throws -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        return try JSONDecoder().decode(Pasteboard.self, from: run(["pasteboard-set", encoded], device: device)).text
    }

    struct Hit: Decodable {
        let element: AccessibilityElement?
        let screen: CGRect
    }

    struct BannerAnswer: Decodable {
        let banner: NotificationBanner?
    }

    struct Pasteboard: Decodable {
        let text: String
    }
}
