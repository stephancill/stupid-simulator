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
            On Apple TV name the app with --app. Its apps list no children to accessibility, so the \
            tree is the app and the element with focus, marked `focused`; read other points with \
            --at x,y and move focus with `stupidsim remote`.
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

    @Flag(help: "Print only the element with focus: on Apple TV, the one the remote acts on.")
    var focused = false

    @Option(help: ArgumentHelp("Read this running app by bundle identifier instead of the app in front. Required on Apple TV, where nothing answers for the app in front.", valueName: "bundle-id"))
    var app: String?

    @Option(help: ArgumentHelp("Print only what is drawn on top at this point, in the normalized coordinates `tap` takes, whichever process draws it: for example the Send button of a notification reply.", valueName: "x,y"), transform: UITree.point)
    var at: CGPoint?

    func validate() throws {
        if at != nil, springboard {
            throw ValidationError("--at reads whatever is on top, so it does not take --springboard.")
        }
        if springboard, app != nil {
            throw ValidationError("--springboard and --app each name what to read; pass one.")
        }
        if focused, at != nil || springboard {
            throw ValidationError("--focused reads the app in front or the one --app names, so it does not take --at or --springboard.")
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
        let host = try SimulatorHosts.current()
        if focused {
            guard let element = try host.accessibilityFocusedElement(udid, app: app) else {
                throw EngineError.capabilityUnavailable(name: "an element with focus")
            }
            try await printAlone(element, screen: nil, host: host)
            return
        }
        if let at {
            try await printElement(at: at, host: host)
            return
        }
        var root = try app.map { try host.accessibilityTree(udid, app: $0) }
            ?? host.accessibilityTree(udid, springboard: springboard)
        if let app, root.children.isEmpty, try host.isTV(udid),
           let focusedElement = try host.accessibilityFocusedElement(udid, app: app) {
            root.children = [focusedElement]
            FileHandle.standardError.write(Data("""
                Apple TV apps list no children to accessibility, so only the element with focus is shown. \
                Read other points with --at x,y.\n
                """.utf8))
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(root), as: UTF8.self))
            return
        }
        let orientation = try await host.orientation(udid)
        printTree(root, screen: root.frame, orientation: orientation, depth: 0)
    }

    private func printAlone(_ element: AccessibilityElement, screen: CGRect?, host: any SimulatorHost) async throws {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(element), as: UTF8.self))
            return
        }
        let screen = try screen ?? (app.map { try host.accessibilityTree(udid, app: $0) }
            ?? host.accessibilityTree(udid, springboard: false)).frame
        let orientation = try await host.orientation(udid)
        printTree(element, screen: screen, orientation: orientation, depth: 0)
    }

    private func printElement(at native: CGPoint, host: any SimulatorHost) async throws {
        let orientation = try await host.orientation(udid)
        let shown = CoordinateMapper.shownPoint(fromPortraitNative: native, orientation: orientation)
        let found = try app.map { try host.accessibilityElement(udid, at: shown, app: $0) }
            ?? host.accessibilityElement(udid, at: shown)
        guard let hit = found else {
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
        if !labelled || element.isLabelled {
            let indent = String(repeating: "  ", count: labelled ? 0 : depth)
            print(indent + element.line(center: element.normalizedCenter(in: screen, orientation: orientation)))
        }
        for child in element.children {
            printTree(child, screen: screen, orientation: orientation, depth: depth + 1)
        }
    }
}
