import ArgumentParser
import CoreGraphics
import Foundation
import OpenDeviceHubEngine

struct UITree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-tree",
        abstract: "Print the accessibility tree of the app in front on a booted simulator.",
        discussion: """
            Each line ends with the element's centre in the normalized coordinates `tap` takes, so a \
            line such as `Button "Save" @ 0.50,0.91` is tapped with `--x 0.50 --y 0.91`. Elements \
            scrolled off screen have no centre.
            """
    )

    @Argument(help: ArgumentHelp(stringLiteral: DeviceArgument.help), transform: DeviceArgument.resolve)
    var udid: String

    @Flag(help: "Print the whole tree as JSON, frames in points.")
    var json = false

    @Flag(help: "Only print elements that carry a label, title, identifier or value.")
    var labelled = false

    @Flag(help: "Read SpringBoard instead of the app in front: notification banners, Notification Center, the lock screen and the home screen.")
    var springboard = false

    @Option(help: ArgumentHelp("Print only what is drawn on top at this point, in the normalized coordinates `tap` takes, whichever process draws it: for example the Send button of a notification reply.", valueName: "x,y"), transform: UITree.point)
    var at: CGPoint?

    func validate() throws {
        if at != nil, springboard {
            throw ValidationError("--at reads whatever is on top, so it does not take --springboard.")
        }
    }

    static func point(_ argument: String) throws -> CGPoint {
        let parts = argument.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts.allSatisfy({ (0...1).contains($0) }) else {
            throw ValidationError("--at takes x,y between 0 and 1, such as 0.5,0.9.")
        }
        return CGPoint(x: parts[0], y: parts[1])
    }

    func run() async throws {
        let adapter = try AdapterFactory.make(for: XcodeLocator.locate())
        if let at {
            try await printElement(at: at, adapter: adapter)
            return
        }
        let target: AccessibilityTarget = springboard
            ? .process(pid: try SimctlService().springBoardPID(udid: udid))
            : .frontmost
        let root = try adapter.accessibilityTree(udid, target: target)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(root), as: UTF8.self))
            return
        }
        let orientation = try await DeviceOrientation.current(adapter, udid: udid)
        printTree(root, screen: root.frame, orientation: orientation, depth: 0)
    }

    private func printElement(at native: CGPoint, adapter: any SimulatorAdapter) async throws {
        let orientation = try await DeviceOrientation.current(adapter, udid: udid)
        let shown = CoordinateMapper.shownPoint(fromPortraitNative: native, orientation: orientation)
        guard let hit = try adapter.accessibilityElement(udid, at: shown) else {
            throw EngineError.capabilityUnavailable(name: "an accessible element at \(native.x),\(native.y)")
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(hit.element), as: UTF8.self))
            return
        }
        printTree(hit.element, screen: hit.screen, orientation: orientation, depth: 0)
    }

    private func printTree(_ element: AccessibilityElement, screen: CGRect, orientation: DeviceOrientation, depth: Int) {
        let isLabelled = element.label != nil || element.title != nil
            || element.identifier != nil || element.value != nil
        if !labelled || isLabelled {
            let indent = String(repeating: "  ", count: labelled ? 0 : depth)
            print(indent + describe(element, screen: screen, orientation: orientation))
        }
        for child in element.children {
            printTree(child, screen: screen, orientation: orientation, depth: depth + 1)
        }
    }

    private func describe(_ element: AccessibilityElement, screen: CGRect, orientation: DeviceOrientation) -> String {
        var parts = [role(of: element)]
        if let label = element.label { parts.append("\"\(label)\"") }
        if let title = element.title, title != element.label { parts.append("title=\"\(title)\"") }
        if let value = element.value { parts.append("value=\"\(value)\"") }
        if let identifier = element.identifier { parts.append("id=\(identifier)") }
        if let center = element.normalizedCenter(in: screen, orientation: orientation) {
            parts.append(String(format: "@ %.2f,%.2f", center.x, center.y))
        }
        return parts.joined(separator: " ")
    }

    private func role(of element: AccessibilityElement) -> String {
        guard let role = element.role, !role.isEmpty else {
            return element.roleDescription ?? "Element"
        }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}
