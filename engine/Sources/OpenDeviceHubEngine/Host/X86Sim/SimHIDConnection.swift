import CoreGraphics
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A connection to x86Sim's simhid, the device's stand in for the Mac's SimulatorHID. It reads text
/// lines from a Unix socket in the device's data directory and acts on each without answering.
/// The protocol, from x86Sim 0.3.0's `cli/libexec/simtouch.py` and `host/simhid`:
///
///     touch down|move|up <x> <y> [edge]           one contact, normalized 0...1, portrait native
///     touch2 down|move|up <x1> <y1> <x2> <y2>     two contacts
///     key down|up <usage>                         keyboard usage page (7)
///     button <name> down|up                       home lock volup voldown siri action ...
///     orientation [<name>]                        sets the orientation, then writes the one it
///                                                 ends up in to data/orientation
public final class SimHIDConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    public init(socket: URL) throws {
        // A long device path is a symlink to a short socket, since sun_path holds 108 bytes.
        descriptor = try Self.connectedDescriptor(path: socket.resolvingSymlinksInPath().path, what: "simhid's socket")
    }

    /// A Unix socket connected to `path`; `what` names it in errors.
    static func connectedDescriptor(path: String, what: String) throws -> Int32 {
        let fd = Self.socketDescriptor()
        guard fd >= 0 else { throw Self.posixError("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            _ = Self.closeDescriptor(fd)
            throw X86SimError.failed("\(what) path is too long for a Unix socket: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = Self.posixError("connect to \(path)")
            _ = Self.closeDescriptor(fd)
            throw error
        }
        return fd
    }

    /// Writes whole lines, each ending in a newline.
    public func send(_ lines: [String]) throws {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        try lock.withLock {
            guard descriptor >= 0 else { throw EngineError.inputSessionClosed }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Self.posixError("write to simhid")
                    }
                    offset += written
                }
            }
        }
    }

    public func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            _ = Self.closeDescriptor(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }

    // MARK: - Lines

    /// The line for one touch event. simhid takes the edge only with the first contact, as Apple's
    /// Simulator marks it, and has no cancel, so a cancelled contact lifts.
    public static func lines(for event: TouchEvent) throws -> [String] {
        let phase = switch event.phase {
        case .began: "down"
        case .moved: "move"
        case .ended, .cancelled: "up"
        }
        switch event.points.count {
        case 1:
            let point = event.points[0]
            var line = "touch \(phase) \(coordinate(point.x)) \(coordinate(point.y))"
            if event.phase == .began, let edge = edgeName(event.edge) { line += " \(edge)" }
            return [line]
        case 2:
            let (a, b) = (event.points[0], event.points[1])
            return ["touch2 \(phase) \(coordinate(a.x)) \(coordinate(a.y)) \(coordinate(b.x)) \(coordinate(b.y))"]
        default:
            throw X86SimError.unsupported(what: "Touching with \(event.points.count) fingers at once")
        }
    }

    public static func lines(for event: KeyEvent) -> [String] {
        ["key \(event.phase == .down ? "down" : "up") \(event.usage)"]
    }

    public static func lines(for button: HardwareButton, phase: ButtonPhase) throws -> [String] {
        ["button \(try buttonName(button)) \(phase == .down ? "down" : "up")"]
    }

    /// simhid's names for the buttons it has. The Camera Control and the software keyboard's Eject
    /// key are not among them in x86Sim 0.3.0.
    static func buttonName(_ button: HardwareButton) throws -> String {
        switch button {
        case .home: "home"
        case .lock: "lock"
        case .volumeUp: "volup"
        case .volumeDown: "voldown"
        case .siri: "siri"
        case .actionButton: "action"
        case .cameraControl: throw X86SimError.unsupported(what: "The Camera Control button")
        case .softwareKeyboard: throw X86SimError.unsupported(what: "Showing and hiding the software keyboard")
        case .playPause: throw X86SimError.unsupported(what: "The Apple TV remote's Play/Pause button")
        }
    }

    static func edgeName(_ edge: TouchEvent.Edge) -> String? {
        switch edge {
        case .none: nil
        case .top: "top"
        case .left: "left"
        case .bottom: "bottom"
        case .right: "right"
        }
    }

    /// Five decimals, as simtouch.py writes them: a hundredth of a pixel on the largest screens.
    static func coordinate(_ value: CGFloat) -> String {
        String(format: "%.5f", Double(min(max(value, 0), 1)))
    }

    // MARK: - POSIX

    static func socketDescriptor() -> Int32 {
        #if canImport(Glibc)
        socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    static func closeDescriptor(_ fd: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }

    static func posixError(_ what: String) -> Error {
        X86SimError.failed("Could not \(what): \(String(cString: strerror(errno))).")
    }
}

/// Input for one x86Sim device, sent as simhid lines.
final class SimHIDInputSession: InputSession, @unchecked Sendable {
    private let connection: SimHIDConnection

    init(device: X86SimDevice) throws {
        do {
            connection = try SimHIDConnection(socket: device.inputSocket)
        } catch {
            throw X86SimError.notBooted(name: device.name)
        }
    }

    func touch(_ event: TouchEvent) async throws {
        try connection.send(try SimHIDConnection.lines(for: event))
    }

    func key(_ event: KeyEvent) async throws {
        try connection.send(SimHIDConnection.lines(for: event))
    }

    func button(_ button: HardwareButton, phase: ButtonPhase) async throws {
        try connection.send(try SimHIDConnection.lines(for: button, phase: phase))
    }

    func close() {
        connection.close()
    }
}
