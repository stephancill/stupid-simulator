import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// stupidsim-guest kept running in a device (`stupidsim-guest serve <socket>`), so a tree read does
/// not start a program each time. Starting one took 0.27 s of a 0.5 s tree read on a 20-core
/// desktop, and about half of the ~1 s a read took in a 4-vCPU cloud session (x86Sim 0.5.0, iOS
/// 27.2). Each connection sends one line, a JSON array of the command and its arguments, and reads
/// the JSON answer until the server closes it.
///
/// The server is started on first use and ends with the device. Its socket is named after the
/// guest program's contents, so a newer stupidsim never asks an older server.
struct GuestServer {
    let helper: GuestHelper
    let device: X86SimDevice

    /// How Darling shows the Linux root to programs in the device (x86Sim's mksimdevice.py, DARLING_VIEW).
    static let darlingView = "/Volumes/SystemRoot"
    /// sun_path holds 104 bytes on Darwin, which is what the guest binds with.
    static let guestPathLimit = 104
    /// The first start translates AXRuntime's code paths; later boots find them in the cache.
    static let startTimeout: TimeInterval = 30
    /// As long as a one-shot read is given.
    static let answerTimeout = GuestHelper.timeoutSeconds

    /// Answers one guest command, starting the server if none answers.
    func request(_ arguments: [String]) throws -> Data {
        let socket = try socketPath()
        if let answer = try? Self.ask(arguments, socket: socket) {
            return try Self.checked(answer, command: arguments.first ?? "")
        }
        try start(socket: socket)
        return try Self.checked(Self.ask(arguments, socket: socket), command: arguments.first ?? "")
    }

    /// The JSON answer, or the guest's error as a thrown error.
    static func checked(_ answer: Data, command: String) throws -> Data {
        if let failure = try? JSONDecoder().decode(GuestFailure.self, from: answer) {
            throw X86SimError.guest(command: command, message: failure.error)
        }
        return answer
    }

    // MARK: - Socket

    /// In the device's data directory, beside simhid's, unless that path is too long for the guest
    /// to bind as Darling shows it; then in /run/user/<uid>, which boot-a64.sh makes.
    func socketPath() throws -> String {
        let build = try Self.buildID(of: helper.program)
        let preferred = device.dataDirectory.appending(path: "stupidsim-guest-\(build).sock").path
        if (Self.darlingView + preferred).utf8.count < Self.guestPathLimit {
            return preferred
        }
        let short = "/run/user/\(getuid())/stupidsim-guest-\(Self.fnv1a(Data(device.directory.path.utf8)))-\(build).sock"
        guard (Self.darlingView + short).utf8.count < Self.guestPathLimit else {
            throw X86SimError.failed("No path for the guest's socket fits a Unix socket: \(short)")
        }
        return short
    }

    static func buildID(of program: URL) throws -> String {
        fnv1a(try Data(contentsOf: program))
    }

    static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash & 0xffff_ffff, radix: 16)
    }

    /// One request on a new connection.
    static func ask(_ arguments: [String], socket path: String) throws -> Data {
        let fd = try Self.connect(path)
        defer { _ = Self.closeDescriptor(fd) }
        var timeout = timeval(tv_sec: Self.answerTimeout, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var line = try JSONSerialization.data(withJSONObject: arguments)
        line.append(0x0A)
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError("write to the guest server")
                }
                offset += written
            }
        }
        var answer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let got = read(fd, &chunk, chunk.count)
            if got < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw X86SimError.guest(command: arguments.first ?? "", message: "the guest server did not answer within \(Self.answerTimeout) s")
                }
                throw Self.posixError("read from the guest server")
            }
            if got == 0 { break }
            answer.append(contentsOf: chunk[0..<got])
        }
        guard !answer.isEmpty else {
            throw X86SimError.guest(command: arguments.first ?? "", message: "the guest server closed the connection without answering")
        }
        return answer
    }

    static func connect(_ path: String) throws -> Int32 {
        try SimHIDConnection.connectedDescriptor(path: path, what: "The guest's socket")
    }

    // MARK: - Starting

    /// Starts the server and waits for its socket to answer. A lock beside the socket keeps two
    /// commands from starting one each.
    func start(socket path: String) throws {
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw Self.posixError("open \(path).lock") }
        defer { _ = Self.closeDescriptor(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw Self.posixError("lock \(path).lock") }
        defer { _ = flock(lock, LOCK_UN) }
        if (try? Self.ask(["ping"], socket: path)) != nil { return }

        // x86Sim's spawn returns once its timeout passes and leaves the program running; it exits
        // non-zero then, saying so. Anything else means the server ended.
        let result = try helper.install.launch(
            helper.install.commandLine(["spawn", "--timeout", "2", helper.program.path, "serve", Self.darlingView + path]),
            standardInput: nil,
            environment: ["X86SIM_DEVICE": device.directory.path, "A64_DEVICE": device.directory.path]
        )
        let output = (result.standardOutput + result.standardError).trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.contains("still running") else {
            let tail = output.split(separator: "\n").suffix(5).joined(separator: "\n")
            throw X86SimError.guest(command: "serve", message: "the guest server ended at once (status \(result.status)): \(tail)")
        }
        let deadline = Date().addingTimeInterval(Self.startTimeout)
        while Date() < deadline {
            if (try? Self.ask(["ping"], socket: path)) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw X86SimError.guest(command: "serve", message: "the guest server did not answer on \(path) within \(Int(Self.startTimeout)) s")
    }

    // MARK: - POSIX

    static func posixError(_ what: String) -> Error { SimHIDConnection.posixError(what) }

    static func closeDescriptor(_ fd: Int32) -> Int32 { SimHIDConnection.closeDescriptor(fd) }
}

private struct GuestFailure: Decodable {
    let error: String
}

