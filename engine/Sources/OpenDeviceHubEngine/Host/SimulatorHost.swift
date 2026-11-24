import CoreGraphics
import Foundation

/// What the command line asks of wherever its simulators run, so every command reads and drives a
/// device the same way on a Mac (Xcode's CoreSimulator) and on Linux (x86Sim).
public protocol SimulatorHost: Sendable {
    /// Every device the host knows about, booted or not.
    func devices() throws -> [DeviceInfo]
    func openInput(_ udid: String) throws -> any InputSession
    /// Turns the device itself, which makes the guest re-lay out.
    func setOrientation(_ orientation: DeviceOrientation, udid: String) throws
    /// The main screen's rotation now, which turns accessibility frames into `tap` coordinates.
    func orientation(_ udid: String) async throws -> DeviceOrientation
    /// The app in front, or SpringBoard: notification banners, Notification Center, the lock
    /// screen and the home screen.
    func accessibilityTree(_ udid: String, springboard: Bool) throws -> AccessibilityElement
    /// One running app's tree by bundle identifier, whether or not it is in front. The only way to
    /// read an app on Apple TV, where nothing answers for the app in front.
    func accessibilityTree(_ udid: String, app bundleID: String) throws -> AccessibilityElement
    /// The element with focus in the app in front, or in a named app, or nil when nothing has focus.
    func accessibilityFocusedElement(_ udid: String, app bundleID: String?) throws -> AccessibilityElement?
    /// What is drawn at a point inside one named app.
    func accessibilityElement(_ udid: String, at shown: CGPoint, app bundleID: String) throws -> AccessibilityHit?
    /// Whether the device is an Apple TV, which is driven with the remote and read by app.
    func isTV(_ udid: String) throws -> Bool
    /// What is drawn on top at a point normalized to the guest's rotated screen, whichever process
    /// draws it, or nil when nothing accessible is there.
    func accessibilityElement(_ udid: String, at shown: CGPoint) throws -> AccessibilityHit?
    /// The notification banner on screen, or nil when there is none.
    func notificationBanner(_ udid: String) throws -> NotificationBanner?
    /// Performs one of the banner's accessibility actions, failing when there is no banner.
    func performBannerAction(_ action: NotificationBannerAction, udid: String) throws
    /// The screen as a PNG.
    func screenshot(_ udid: String) throws -> Data
    /// The screen as pixels, for telling whether input changed it.
    func screenFrame(_ udid: String) throws -> ScreenFrame
    /// How long the screen has gone without a new frame, or nil when the host cannot tell (its
    /// frames are taken on request, not published on change).
    func screenStillFor(_ udid: String) throws -> TimeInterval?
    /// Delivers a remote notification payload, as `simctl push` does.
    func push(_ payload: String, bundleID: String?, udid: String) throws
    func setPasteboard(_ text: String, udid: String) throws
    func pasteboard(_ udid: String) throws -> String
}

extension SimulatorHost {
    public func screenStillFor(_ udid: String) throws -> TimeInterval? { nil }

    public func accessibilityTree(_ udid: String, app bundleID: String) throws -> AccessibilityElement {
        throw EngineError.capabilityUnavailable(name: "reading an app by bundle identifier")
    }

    public func accessibilityFocusedElement(_ udid: String, app bundleID: String?) throws -> AccessibilityElement? {
        throw EngineError.capabilityUnavailable(name: "the focused element")
    }

    public func accessibilityElement(_ udid: String, at shown: CGPoint, app bundleID: String) throws -> AccessibilityHit? {
        throw EngineError.capabilityUnavailable(name: "reading an app by bundle identifier")
    }

    public func isTV(_ udid: String) throws -> Bool {
        guard let device = try devices().first(where: { $0.udid == udid }) else {
            throw EngineError.deviceNotFound(udid: udid)
        }
        return RuntimeIdentifier.isTV(device.runtimeIdentifier)
    }
}

public enum SimulatorHosts {
    /// The host this build drives: CoreSimulator through the active Xcode on a Mac, x86Sim
    /// elsewhere.
    public static func current() throws -> any SimulatorHost {
        #if os(macOS)
        try XcodeSimulatorHost()
        #else
        try X86SimHost()
        #endif
    }
}
