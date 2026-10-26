import AppKit
import Darwin
import Foundation
import OpenDeviceHubEngine

/// Keeps a simulator to one window across every copy of the viewer running for this user. Each
/// `stupidsim view` starts its own viewer process, as does a second copy of the app, and each has
/// its own `DeviceWindowManager`, so the manager's own bookkeeping cannot see the others.
///
/// A window holds an exclusive `flock` on a file named after its device. The kernel lets go of the
/// lock when the process exits however it exits, so a crash never leaves a device unopenable.
@MainActor
public final class DeviceWindowClaims {
    private let directory: URL
    private var held: [String: Int32] = [:]

    public init(directory: URL = DeviceWindowClaims.defaultDirectory) {
        self.directory = directory
    }

    /// Caches rather than the temporary directory, because a terminal can carry its own `TMPDIR`
    /// and the app launched from the Finder would then look somewhere else.
    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Brand.bundleIdentifier)
            .appending(path: "windows")
    }

    /// Takes the device for this process, or throws naming the process that has it. Taking one
    /// already held here succeeds.
    public func claim(_ udid: String) throws {
        let key = udid.uppercased()
        guard held[key] == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "\(key).lock").path(percentEncoded: false)
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw DeviceWindowError.claimFailed(udid: udid, reason: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            let owner = Self.owner(of: descriptor)
            close(descriptor)
            guard reason == EWOULDBLOCK else {
                throw DeviceWindowError.claimFailed(udid: udid, reason: String(cString: strerror(reason)))
            }
            throw DeviceWindowError.openElsewhere(udid: udid, pid: owner)
        }
        // The pid is only for the message a refused process shows. The lock is what decides.
        let pid = Data("\(getpid())".utf8)
        ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        held[key] = descriptor
    }

    public func release(_ udid: String) {
        guard let descriptor = held.removeValue(forKey: udid.uppercased()) else { return }
        // Closing the last descriptor drops the lock. The file stays, since unlinking it could race
        // another process that has just opened it and is about to lock it.
        close(descriptor)
    }

    public func holds(_ udid: String) -> Bool {
        held[udid.uppercased()] != nil
    }

    private static func owner(of descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return pid_t(String(decoding: buffer[..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum DeviceWindowError: Error, LocalizedError, Equatable {
    case openElsewhere(udid: String, pid: pid_t?)
    case claimFailed(udid: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .openElsewhere(_, let pid):
            let owner = pid.map { " (pid \($0))" } ?? ""
            return "already shown by another \(Brand.productName) window\(owner)"
        case .claimFailed(_, let reason):
            return "could not check whether another window shows it: \(reason)"
        }
    }
}

/// Asks whichever process has a device's window to bring it forward. The process that was refused
/// posts this, since the person asked to see the device and a refusal alone would look like nothing
/// happened.
public enum DeviceWindowRequest {
    public static let showDevice = Notification.Name("\(Brand.bundleIdentifier).showDevice")

    public static func show(_ udid: String, ownedBy pid: pid_t?) {
        DistributedNotificationCenter.default().postNotificationName(
            showDevice,
            object: udid.uppercased(),
            userInfo: nil,
            deliverImmediately: true
        )
        // The owner cannot activate itself from the background since macOS 14, so the process the
        // person is using hands activation over.
        if let pid, let owner = NSRunningApplication(processIdentifier: pid) {
            owner.activate()
        }
    }
}
