#if os(macOS)
import CoreGraphics
import Foundation

/// Simulators run by the active Xcode's CoreSimulator: the private adapter for input, accessibility
/// display state and screenshots, and simctl for pushes and the pasteboard.
public struct XcodeSimulatorHost: SimulatorHost {
    public let adapter: any SimulatorAdapter
    private let simctl = SimctlService()

    public init() throws {
        adapter = try AdapterFactory.make(for: XcodeLocator.locate())
    }

    public func devices() throws -> [DeviceInfo] {
        try adapter.devices()
    }

    public func openInput(_ udid: String) throws -> any InputSession {
        try adapter.openInput(udid)
    }

    public func setOrientation(_ orientation: DeviceOrientation, udid: String) throws {
        try adapter.setOrientation(orientation, udid: udid)
    }

    public func orientation(_ udid: String) async throws -> DeviceOrientation {
        let report = try await adapter.displayReport(udid)
        // Accessibility's display 0 denotes the main screen; CoreDevice uses its own display IDs.
        guard report.isSettled, let display = report.activeIntegrated,
              let orientation = DeviceOrientation.allCases.first(where: { $0.degrees == display.currentRotation }) else {
            throw EngineError.capabilityUnavailable(name: "the accessibility display's rotation")
        }
        return orientation
    }

    public func accessibilityTree(_ udid: String, springboard: Bool) throws -> AccessibilityElement {
        let target: AccessibilityTarget = springboard
            ? .process(pid: try simctl.springBoardPID(udid: udid))
            : .frontmost
        return try adapter.accessibilityTree(udid, target: target)
    }

    public func accessibilityElement(_ udid: String, at shown: CGPoint) throws -> AccessibilityHit? {
        try adapter.accessibilityElement(udid, at: shown)
    }

    public func notificationBanner(_ udid: String) throws -> NotificationBanner? {
        try adapter.notificationBanner(udid)
    }

    public func performBannerAction(_ action: NotificationBannerAction, udid: String) throws {
        try adapter.performBannerAction(action, udid: udid)
    }

    /// From the framebuffer rather than `simctl io screenshot`, which hides the Dynamic Island
    /// while it captures; see `FramebufferCapture`.
    public func screenshot(_ udid: String) throws -> Data {
        try FramebufferCapture.png(adapter: adapter, udid: udid)
    }

    public func screenFrame(_ udid: String) throws -> ScreenFrame {
        try ScreenFrame(image: FramebufferCapture.image(adapter: adapter, udid: udid))
    }

    public func push(_ payload: String, bundleID: String?, udid: String) throws {
        try simctl.push(payload, bundleID: bundleID, udid: udid)
    }

    public func setPasteboard(_ text: String, udid: String) throws {
        try simctl.pasteboardCopy(text, udid: udid)
    }

    public func pasteboard(_ udid: String) throws -> String {
        try simctl.pasteboardPaste(udid: udid)
    }
}
#endif
