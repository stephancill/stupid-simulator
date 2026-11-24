import CoreGraphics
import Foundation

extension AccessibilityElement {
    /// The role as `ui-tree` prints it: `Button` rather than `AXButton`.
    public var displayRole: String {
        guard let role, !role.isEmpty else { return roleDescription ?? "Element" }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    public var isLabelled: Bool {
        label != nil || title != nil || identifier != nil || value != nil
    }

    /// One `ui-tree` line, such as `Button "Save" id=save @ 0.50,0.91`.
    public func line(center: CGPoint?) -> String {
        var parts = [displayRole]
        if let label { parts.append("\"\(label)\"") }
        if let title, title != label { parts.append("title=\"\(title)\"") }
        if let value { parts.append("value=\"\(value)\"") }
        if let identifier { parts.append("id=\(identifier)") }
        if focused == true { parts.append("focused") }
        if let center { parts.append(String(format: "@ %.2f,%.2f", center.x, center.y)) }
        return parts.joined(separator: " ")
    }
}

/// Finds elements in a tree the way an agent would read `ui-tree`, so `tap --label` and `wait` act
/// on what `ui-tree` printed instead of on coordinates copied out of it.
public struct AccessibilityQuery: Sendable, Hashable {
    /// Matches the label or title: exactly when any element matches exactly, otherwise as a
    /// case-insensitive substring, which is what agents grepped for.
    public var label: String?
    /// Matches the identifier exactly.
    public var identifier: String?
    /// Matches the role as `ui-tree` prints it (`Button`, `TextField`), ignoring case.
    public var role: String?

    public init(label: String? = nil, identifier: String? = nil, role: String? = nil) {
        self.label = label
        self.identifier = identifier
        self.role = role
    }

    public var isEmpty: Bool { label == nil && identifier == nil && role == nil }

    /// What the query asks for, for messages: `Button "Send" id=send`.
    public var summary: String {
        var parts: [String] = []
        if let role { parts.append(role) }
        if let label { parts.append("\"\(label)\"") }
        if let identifier { parts.append("id=\(identifier)") }
        return parts.joined(separator: " ")
    }

    /// An element that matched, with its `tap` centre, or nil when it is off screen.
    public struct Match: Sendable, Hashable {
        public var element: AccessibilityElement
        public var center: CGPoint?
        public var line: String { element.line(center: center) }
    }

    /// Every match in the order `ui-tree` prints them.
    public func matches(
        in root: AccessibilityElement,
        screen: CGRect,
        orientation: DeviceOrientation = .portrait
    ) -> [Match] {
        var candidates: [AccessibilityElement] = []
        // The root is the app itself (`Application "Settings"`), never something to tap, and its
        // label would make the app's name match it as well as the Back button that carries it.
        for child in root.children {
            Self.walk(child) { element in
                if self.matchesRoleAndIdentifier(element) { candidates.append(element) }
            }
        }
        if let label {
            let exact = candidates.filter { $0.label == label || $0.title == label }
            if !exact.isEmpty {
                candidates = exact
            } else {
                candidates = candidates.filter {
                    ($0.label?.localizedCaseInsensitiveContains(label) ?? false)
                        || ($0.title?.localizedCaseInsensitiveContains(label) ?? false)
                }
            }
        }
        return candidates.map { Match(element: $0, center: $0.normalizedCenter(in: screen, orientation: orientation)) }
    }

    /// The one element to act on.
    ///
    /// Off-screen matches are ignored when any match is on screen, since nothing off screen can be
    /// tapped. Matches with the same centre (a cell and its own text) count as one. More than one
    /// left is an error unless `index` (1-based, in `ui-tree` order) picks one.
    public func resolve(_ matches: [Match], index: Int? = nil) -> Resolution {
        let onScreen = matches.filter { $0.center != nil }
        guard !onScreen.isEmpty else {
            return matches.isEmpty ? .notFound : .offScreen(matches)
        }
        var distinct: [Match] = []
        for match in onScreen {
            guard let center = match.center else { continue }
            let duplicate = distinct.contains { other in
                guard let otherCenter = other.center else { return false }
                return abs(otherCenter.x - center.x) < 0.01 && abs(otherCenter.y - center.y) < 0.01
            }
            if !duplicate { distinct.append(match) }
        }
        if let index {
            guard (1...distinct.count).contains(index) else { return .indexOutOfRange(distinct) }
            return .found(distinct[index - 1])
        }
        return distinct.count == 1 ? .found(distinct[0]) : .ambiguous(distinct)
    }

    public enum Resolution: Sendable, Hashable {
        case found(Match)
        case notFound
        /// Matches exist, but none has a centre on screen.
        case offScreen([Match])
        case ambiguous([Match])
        case indexOutOfRange([Match])
    }

    private func matchesRoleAndIdentifier(_ element: AccessibilityElement) -> Bool {
        if let role, element.displayRole.caseInsensitiveCompare(role) != .orderedSame { return false }
        if let identifier, element.identifier != identifier { return false }
        if label != nil, element.label == nil, element.title == nil { return false }
        return true
    }

    private static func walk(_ element: AccessibilityElement, _ visit: (AccessibilityElement) -> Void) {
        visit(element)
        for child in element.children { walk(child, visit) }
    }
}
