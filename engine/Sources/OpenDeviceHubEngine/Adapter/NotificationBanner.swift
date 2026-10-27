import AppKit
import CoreGraphics
import Foundation
import OpenDeviceHubPrivate

/// A notification banner SpringBoard is showing over whatever is in front.
public struct NotificationBanner: Codable, Sendable, Hashable {
    /// What VoiceOver reads: the app's name, when it arrived, then the title, subtitle and body,
    /// joined by ", ". For example "STUPID SOCIAL, now, Hello, World".
    public var label: String
    /// In the guest's points.
    public var frame: CGRect
    /// SpringBoard's whole screen in the same points, which `frame` is measured against.
    public var screen: CGRect
    /// The banner's accessibility actions, "More" and "Dismiss" on Xcode 27 (27A266a).
    public var actions: [String]

    public init(label: String, frame: CGRect, screen: CGRect, actions: [String]) {
        self.label = label
        self.frame = frame
        self.screen = screen
        self.actions = actions
    }

    /// The centre in the normalized coordinates `tap` takes, or nil when it is off screen.
    public func normalizedCenter(orientation: DeviceOrientation = .portrait) -> CGPoint? {
        AccessibilityElement(frame: frame, children: []).normalizedCenter(in: screen, orientation: orientation)
    }

    /// Whether every expected piece of text is somewhere in the banner.
    public func contains(_ expected: [String]) -> Bool {
        expected.allSatisfy { label.localizedCaseInsensitiveContains($0) }
    }
}

/// Accessibility custom actions a banner offers, by the names SpringBoard gives them.
public enum NotificationBannerAction: String, Sendable, CaseIterable {
    /// Expands the banner into the long look, with the notification's own actions.
    case more = "More"
    case dismiss = "Dismiss"
}

// Verified on Xcode 27 (27A266a) with an iOS 27.0 device: in SpringBoard's tree a banner is an AXGroup
// labelled "Notification" with no children. Hit testing its centre answers the
// NotificationShortLookView inside it, which carries the text and the custom actions. Identified by
// that identifier rather than the group's label, which is localized.
extension AccessibilityTreeReader {
    static let shortLookIdentifier = "NotificationShortLookView"

    /// The banner on screen, or nil when there is none. The reader must target SpringBoard.
    func banner() throws -> NotificationBanner? {
        try withRoot { translator, token, root in
            try Self.shortLook(in: root, translator: translator, token: token).map { element in
                NotificationBanner(
                    label: element.platform.accessibilityLabel ?? "",
                    frame: element.platform.accessibilityFrame,
                    screen: unsafeBitCast(root as AnyObject, to: (any ODHAXPMacPlatformElement).self).accessibilityFrame,
                    actions: Self.customActions(of: element.object).compactMap { Self.name(of: $0) }
                )
            }
        }
    }

    /// Performs one of the banner's custom actions. Fails when there is no banner or it does not offer
    /// the action.
    func performBannerAction(_ action: NotificationBannerAction) throws {
        try withRoot { translator, token, root in
            guard let element = try Self.shortLook(in: root, translator: translator, token: token) else {
                throw EngineError.capabilityUnavailable(name: "a notification banner (none is showing)")
            }
            let actions = Self.customActions(of: element.object)
            guard let custom = actions.first(where: { Self.name(of: $0) == action.rawValue }) else {
                let offered = actions.compactMap { Self.name(of: $0) }.joined(separator: ", ")
                throw EngineError.capabilityUnavailable(
                    name: "the banner action \(action.rawValue) (the banner offers: \(offered))"
                )
            }
            guard try Self.perform(custom) else {
                throw EngineError.privateCall(
                    symbol: "NSAccessibilityCustomAction",
                    message: "the banner refused \(action.rawValue)"
                )
            }
        }
    }

    private struct ShortLook {
        let object: AnyObject
        let platform: any ODHAXPMacPlatformElement
    }

    private static func shortLook(
        in root: Any,
        translator: any ODHAXPTranslator,
        token: String
    ) throws -> ShortLook? {
        let rootPlatform = unsafeBitCast(root as AnyObject, to: (any ODHAXPMacPlatformElement).self)
        for child in rootPlatform.accessibilityChildren ?? [] {
            let group = unsafeBitCast(child as AnyObject, to: (any ODHAXPMacPlatformElement).self)
            guard group.accessibilityRole == "AXGroup", group.accessibilityChildren?.isEmpty ?? true,
                  !group.accessibilityFrame.isEmpty else { continue }
            let centre = CGPoint(x: group.accessibilityFrame.midX, y: group.accessibilityFrame.midY)
            guard let hit = translator.object(at: centre, displayId: 0, bridgeDelegateToken: token) else { continue }
            try setToken(token, on: hit)
            guard let object = translator.macPlatformElement(fromTranslation: hit).map({ $0 as AnyObject }) else { continue }
            try AccessibilitySelectorCheck.require(on: object, selectors: [
                "translation", "accessibilityIdentifier", "accessibilityLabel", "accessibilityFrame",
                "accessibilityCustomActions",
            ])
            let platform = unsafeBitCast(object, to: (any ODHAXPMacPlatformElement).self)
            if let translation = platform.translation {
                try setToken(token, on: translation)
            }
            if platform.accessibilityIdentifier == shortLookIdentifier {
                return ShortLook(object: object, platform: platform)
            }
        }
        return nil
    }

    private static func customActions(of object: AnyObject) -> [AnyObject] {
        let platform = unsafeBitCast(object, to: (any ODHAXPMacPlatformElement).self)
        return (platform.accessibilityCustomActions ?? []).map { $0 as AnyObject }
    }

    private static func name(of action: AnyObject) -> String? {
        (action as? NSAccessibilityCustomAction)?.name
    }

    /// AXPTranslator builds each action with a handler that forwards it to the guest.
    private static func perform(_ action: AnyObject) throws -> Bool {
        guard let custom = action as? NSAccessibilityCustomAction else {
            throw EngineError.privateCall(symbol: "accessibilityCustomActions", message: "an action was not an NSAccessibilityCustomAction")
        }
        if let handler = custom.handler {
            return handler()
        }
        if let target = custom.target as? NSObject, let selector = custom.selector, target.responds(to: selector) {
            return target.perform(selector, with: custom) != nil
        }
        throw EngineError.privateCall(symbol: "NSAccessibilityCustomAction", message: "\(custom.name) has no handler or target")
    }
}
