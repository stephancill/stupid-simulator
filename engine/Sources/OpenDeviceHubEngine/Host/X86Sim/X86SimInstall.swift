import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where x86Sim is: the program that runs its command line, and its data directory.
///
/// x86Sim ships as one AppImage; `<AppImage> x86sim <command>` runs its command line, which follows
/// `xcrun simctl`. stupidsim runs the extracted AppImage's `AppRun`, which takes the same
/// arguments: run as an AppImage, each command left its FUSE helper and mount behind, dozens for
/// one `push --verify` (x86Sim 0.3.0 under WSL 2). stupidsim uses it
/// for what only x86Sim can do (`spawn`, `push`, `view`) and reads devices, frames and input
/// directly otherwise. Verified with x86Sim 0.3.0.
public struct X86SimInstall: Sendable, Hashable {
    /// An extracted AppImage's AppRun.
    public let launcher: URL
    /// x86Sim's data directory, `$X86SIM_DATA`, else `$XDG_DATA_HOME/x86sim`, else
    /// `~/.local/share/x86sim`, as its AppRun decides.
    public let dataRoot: URL

    public static let launcherVariable = "STUPIDSIM_X86SIM"

    public init(launcher: URL, dataRoot: URL) {
        self.launcher = launcher
        self.dataRoot = dataRoot
    }

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> X86SimInstall {
        let home = environment["HOME"].map(URL.init(fileURLWithPath:)) ?? FileManager.default.homeDirectoryForCurrentUser
        let candidates = launcherCandidates(environment: environment, home: home)
        guard let launcher = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw X86SimError.notInstalled(searched: candidates.map(\.path))
        }
        if launcher.pathExtension.lowercased() == "appimage" {
            throw X86SimError.failed("""
                \(launcherVariable) names an AppImage, which leaves a FUSE mount behind for every command. \
                Extract it once (`\(launcher.path) --appimage-extract` makes squashfs-root) and point \
                \(launcherVariable) at squashfs-root/AppRun.
                """)
        }
        let dataRoot = dataRoot(environment: environment, home: home)
        guard FileManager.default.fileExists(atPath: dataRoot.path) else {
            throw X86SimError.noDataDirectory(path: dataRoot.path)
        }
        return X86SimInstall(launcher: launcher, dataRoot: dataRoot)
    }

    /// `$STUPIDSIM_X86SIM` when set, which wins even when it does not exist so a typo is reported
    /// rather than passed over; otherwise where the Linux installer extracts x86Sim.
    static func launcherCandidates(environment: [String: String], home: URL) -> [URL] {
        if let configured = environment[launcherVariable], !configured.isEmpty {
            return [URL(fileURLWithPath: configured)]
        }
        let dataHome = environment["XDG_DATA_HOME"].map(URL.init(fileURLWithPath:)) ?? home.appending(path: ".local/share")
        return [dataHome.appending(path: "stupidsim/x86sim/AppRun")]
    }

    static func dataRoot(environment: [String: String], home: URL) -> URL {
        if let data = environment["X86SIM_DATA"], !data.isEmpty { return URL(fileURLWithPath: data) }
        let dataHome = environment["XDG_DATA_HOME"].map(URL.init(fileURLWithPath:)) ?? home.appending(path: ".local/share")
        return dataHome.appending(path: "x86sim")
    }

    public func devices() throws -> [X86SimDevice] {
        try X86SimDevice.all(in: dataRoot)
    }

    /// The arguments that run `x86sim <arguments>` through the launcher.
    func commandLine(_ arguments: [String]) -> [String] {
        ["x86sim"] + arguments
    }

    /// Runs an x86Sim command for one device and returns its standard output, failing loudly on a
    /// non-zero status.
    @discardableResult
    public func run(_ arguments: [String], device: X86SimDevice?, standardInput: String? = nil) throws -> String {
        let result = try launch(
            commandLine(arguments),
            standardInput: standardInput,
            environment: device.map { ["X86SIM_DEVICE": $0.directory.path, "A64_DEVICE": $0.directory.path] } ?? [:]
        )
        guard result.status == 0 else {
            let output = (result.standardError + result.standardOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            throw X86SimError.commandFailed(command: "x86sim \(arguments.joined(separator: " "))", status: result.status, output: output)
        }
        return result.standardOutput
    }

    /// x86Sim's own version line, such as "x86Sim 0.3.0 (Darling 3239fb8d0e372c54, userns mode)".
    public func version() throws -> String {
        let result = try launch(["version"], standardInput: nil, environment: [:])
        return result.standardOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    struct Result {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs the launcher and waits for it, its output in temporary files.
    ///
    /// An AppImage's runtime forks a FUSE helper that serves the image and exits only once the
    /// AppImage's own process is gone, reaped. Foundation's Process noticed neither the exit, its
    /// child staying a zombie, nor the end of a pipe the helper still held, so every x86Sim command
    /// run through an AppImage hung (x86Sim 0.3.0, Swift 6.2 on Linux). posix_spawn and waitpid
    /// reap it straight away; files instead of pipes leave nothing for the helper to hold open. An
    /// extracted AppRun has no helper and runs the same way.
    func launch(_ arguments: [String], standardInput: String?, environment: [String: String]) throws -> Result {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "stupidsim-x86sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputFile = scratch.appending(path: "out")
        let errorFile = scratch.appending(path: "err")
        var inputPath = "/dev/null"
        if let standardInput {
            let inputFile = scratch.appending(path: "in")
            try Data(standardInput.utf8).write(to: inputFile)
            inputPath = inputFile.path
        }
        let status = try Self.spawnAndWait(
            launcher.path, arguments, environment: environment,
            standardInput: inputPath, standardOutput: outputFile.path, standardError: errorFile.path
        )
        return Result(
            status: status,
            standardOutput: (try? String(contentsOf: outputFile, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
        )
    }

    /// Runs `x86sim <arguments>` attached to this terminal, for x86Sim's viewer, and returns its
    /// exit status once it ends.
    public func runAttached(_ arguments: [String], device: X86SimDevice?) throws -> Int32 {
        try Self.spawnAndWait(
            launcher.path, commandLine(arguments),
            environment: device.map { ["X86SIM_DEVICE": $0.directory.path, "A64_DEVICE": $0.directory.path] } ?? [:],
            standardInput: nil, standardOutput: nil, standardError: nil
        )
    }

    /// posix_spawn and waitpid, with each standard stream from a file, or inherited when nil.
    static func spawnAndWait(
        _ executable: String, _ arguments: [String], environment: [String: String],
        standardInput: String?, standardOutput: String?, standardError: String?
    ) throws -> Int32 {
        #if canImport(Glibc)
        var actions = posix_spawn_file_actions_t()
        #else
        var actions: posix_spawn_file_actions_t?
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let standardInput { posix_spawn_file_actions_addopen(&actions, 0, standardInput, O_RDONLY, 0) }
        if let standardOutput { posix_spawn_file_actions_addopen(&actions, 1, standardOutput, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        if let standardError { posix_spawn_file_actions_addopen(&actions, 2, standardError, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }

        let merged = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, nil, argv, envp)
        guard spawned == 0 else {
            throw X86SimError.failed("Could not start \(executable): \(String(cString: strerror(spawned))).")
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { throw X86SimError.failed("Lost track of \(executable): \(String(cString: strerror(errno))).") }
        }
        // WIFEXITED / WEXITSTATUS, which Swift does not import as functions.
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
