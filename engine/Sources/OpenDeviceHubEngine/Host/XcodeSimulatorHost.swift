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
        // A TV does not rotate and has no integrated display for the report to describe; its
        // frames are already in the native orientation.
        if try isTV(udid) { return .portrait }
        let report = try await adapter.displayReport(udid)
        // Accessibility's display 0 denotes the main screen; CoreDevice uses its own display IDs.
        guard report.isSettled, let display = report.activeIntegrated,
              let orientation = DeviceOrientation.allCases.first(where: { $0.degrees == display.currentRotation }) else {
            throw EngineError.capabilityUnavailable(name: "the accessibility display's rotation")
        }
        return orientation
    }

    public func accessibilityTree(_ udid: String, springboard: Bool) throws -> AccessibilityElement {
        // On tvOS 27.0 (24J360), Xcode 27 (27A266a), frontmostApplicationWithDisplayId answers
        // nothing for any display id, with Settings or the home screen in front; reading a process
        // by pid works.
        if !springboard, try isTV(udid) {
            throw EngineError.unsupportedOnDevice(
                what: "Reading the app in front",
                device: "Apple TV, where no process answers for it",
                instead: "Name the app with --app <bundle id>."
            )
        }
        let target: AccessibilityTarget = springboard
            ? .process(pid: try simctl.springBoardPID(udid: udid))
            : .frontmost
        return try adapter.accessibilityTree(udid, target: target)
    }

    public func accessibilityTree(_ udid: String, app bundleID: String) throws -> AccessibilityElement {
        try adapter.accessibilityTree(udid, target: appTarget(bundleID, udid: udid))
    }

    public func accessibilityFocusedElement(_ udid: String, app bundleID: String?) throws -> AccessibilityElement? {
        try adapter.accessibilityFocusedElement(udid, target: bundleID.map { try appTarget($0, udid: udid) } ?? .frontmost)
    }

    public func accessibilityElement(_ udid: String, at shown: CGPoint, app bundleID: String) throws -> AccessibilityHit? {
        try adapter.accessibilityElement(udid, at: shown, target: appTarget(bundleID, udid: udid))
    }

    private func appTarget(_ bundleID: String, udid: String) throws -> AccessibilityTarget {
        .process(pid: try simctl.applicationPID(bundleID: bundleID, udid: udid))
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
