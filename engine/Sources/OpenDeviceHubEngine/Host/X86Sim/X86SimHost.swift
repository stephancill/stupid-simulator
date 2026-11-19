import CoreGraphics
import Foundation

/// Simulators run by x86Sim on Linux: Apple's iOS simulator runtime translated to x86-64. Input
/// goes straight to the device's simhid socket and frames come straight from its frame ring; the
/// accessibility tree, banners and the pasteboard are read inside the device by stupidsim-guest.
public struct X86SimHost: SimulatorHost {
    public let install: X86SimInstall

    public init() throws {
        install = try X86SimInstall.locate()
    }

    public init(install: X86SimInstall) {
        self.install = install
    }

    /// The device a command named, by UDID or by its x86Sim name.
    public func device(_ argument: String) throws -> X86SimDevice {
        let devices = try install.devices()
        if let match = devices.first(where: { $0.udid.caseInsensitiveCompare(argument) == .orderedSame || $0.name == argument }) {
            return match
        }
        throw X86SimError.deviceNotFound(argument: argument, known: devices.map { "\($0.name) (\($0.udid))" })
    }

    private func bootedDevice(_ argument: String) throws -> X86SimDevice {
        let device = try device(argument)
        guard device.isBooted else { throw X86SimError.notBooted(name: device.name) }
        return device
    }

    private func guest() throws -> GuestHelper {
        try GuestHelper(install: install)
    }

    public func devices() throws -> [DeviceInfo] {
        try install.devices().map { $0.info() }
    }

    public func openInput(_ udid: String) throws -> any InputSession {
        try SimHIDInputSession(device: device(udid))
    }

    public func setOrientation(_ orientation: DeviceOrientation, udid: String) throws {
        let device = try bootedDevice(udid)
        let reached = try requestOrientation(orientation.rawValue, device: device)
        guard reached == orientation else {
            throw X86SimError.failed("The device stayed in \(reached.rawValue) when turned to \(orientation.rawValue).")
        }
    }

    public func orientation(_ udid: String) async throws -> DeviceOrientation {
        try requestOrientation(nil, device: bootedDevice(udid))
    }

    /// Sends `orientation [name]` and waits for simhid to write the orientation the device is in,
    /// as x86Sim's own `orientation` command does.
    private func requestOrientation(_ name: String?, device: X86SimDevice) throws -> DeviceOrientation {
        let file = device.orientationFile
        let before = Self.modificationDate(file)
        let connection = try SimHIDConnection(socket: device.inputSocket)
        defer { connection.close() }
        try connection.send([name.map { "orientation \($0)" } ?? "orientation"])
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            if let written = Self.modificationDate(file), written != before {
                let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let orientation = Self.orientation(named: text) else {
                    throw X86SimError.failed("simhid reported the orientation as \"\(text)\", which is not one stupidsim knows.")
                }
                return orientation
            }
        }
        throw X86SimError.failed("simhid did not report the device's orientation within 2 s.")
    }

    /// simhid writes UIDeviceOrientation's names, which are DeviceOrientation's raw values. A
    /// device that has not been turned since it booted reports "unknown", and its interface is
    /// portrait (x86Sim 0.3.0). faceUp and faceDown say nothing about the interface, so they are
    /// not taken as an orientation.
    static func orientation(named text: String) -> DeviceOrientation? {
        let name = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return name == "unknown" ? .portrait : DeviceOrientation(rawValue: name)
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    public func accessibilityTree(_ udid: String, springboard: Bool) throws -> AccessibilityElement {
        try guest().tree(springboard: springboard, device: bootedDevice(udid))
    }

    public func accessibilityElement(_ udid: String, at shown: CGPoint) throws -> AccessibilityHit? {
        try guest().element(at: shown, device: bootedDevice(udid))
    }

    public func notificationBanner(_ udid: String) throws -> NotificationBanner? {
        try guest().banner(device: bootedDevice(udid))
    }

    /// By gesture, as a person does it: swiping the banner up dismisses it. AXRuntime offers the
    /// banner's More and Dismiss custom actions, but performing one takes an action number it does
    /// not publish, and a wrong number restarted SpringBoard (x86Sim 0.3.0, iOS 27.2). Neither
    /// pulling the banner down nor a long press expanded it there, so More is refused rather than
    /// reported done.
    public func performBannerAction(_ action: NotificationBannerAction, udid: String) throws {
        guard action == .dismiss else {
            throw X86SimError.unsupported(what: "Expanding a notification (and so replying to one)")
        }
        let device = try bootedDevice(udid)
        guard let banner = try guest().banner(device: device) else {
            throw X86SimError.failed("No notification banner is showing.")
        }
        guard banner.actions.contains(action.rawValue) else {
            throw X86SimError.failed("The banner does not offer \(action.rawValue); it offers \(banner.actions.joined(separator: ", ")).")
        }
        let orientation = try requestOrientation(nil, device: device)
        guard let centre = banner.normalizedCenter(orientation: orientation) else {
            throw X86SimError.failed("The banner is not on screen.")
        }
        let end = CGPoint(x: centre.x, y: 0)
        let connection = try SimHIDConnection(socket: device.inputSocket)
        defer { connection.close() }
        let path = TouchPath.points(from: centre, to: end, steps: 16)
        try connection.send(try SimHIDConnection.lines(for: TouchEvent(phase: .began, points: [path[0]])))
        for point in path.dropFirst() {
            Thread.sleep(forTimeInterval: 0.016)
            try connection.send(try SimHIDConnection.lines(for: TouchEvent(phase: .moved, points: [point])))
        }
        try connection.send(try SimHIDConnection.lines(for: TouchEvent(phase: .ended, points: [end])))
    }

    public func screenshot(_ udid: String) throws -> Data {
        let frame = try FrameRing.latest(at: bootedDevice(udid).frameRing)
        return try PNGEncoder.encode(rgb: frame.rgbRows(), width: frame.width, height: frame.height)
    }

    public func screenFrame(_ udid: String) throws -> ScreenFrame {
        try FrameRing.latest(at: bootedDevice(udid).frameRing).screenFrame()
    }

    public func screenStillFor(_ udid: String) throws -> TimeInterval? {
        Date().timeIntervalSince(try FrameRing.lastPublished(at: bootedDevice(udid).frameRing))
    }

    public func push(_ payload: String, bundleID: String?, udid: String) throws {
        let device = try bootedDevice(udid)
        // x86Sim reads the payload from a file or from standard input given as "-".
        try install.run(["push"] + (bundleID.map { [$0] } ?? []) + ["-"], device: device, standardInput: payload)
    }

    public func setPasteboard(_ text: String, udid: String) throws {
        let now = try guest().setPasteboard(text, device: bootedDevice(udid))
        guard now == text else {
            throw X86SimError.failed("The device's pasteboard held something else straight after being set.")
        }
    }

    public func pasteboard(_ udid: String) throws -> String {
        try guest().pasteboard(device: bootedDevice(udid))
    }
}
