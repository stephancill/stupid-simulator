import ArgumentParser
import CoreGraphics
import Foundation
import OpenDeviceHubEngine

/// Picks an element out of the accessibility tree by what `ui-tree` prints, for `tap` and `wait`.
struct ElementOptions: ParsableArguments {
    @Option(help: "The element's label or title, as `ui-tree` prints it in quotes. An exact match wins; otherwise any label containing this text, ignoring case.")
    var label: String?

    @Option(name: .customLong("id"), help: "The element's identifier, as `ui-tree` prints after `id=`.")
    var identifier: String?

    @Option(help: "The element's role, as `ui-tree` prints it first: Button, TextField, Cell...")
    var role: String?

    @Option(help: "Which match to use, counting from 1 in `ui-tree` order, when several are on screen.")
    var index: Int?

    @Flag(help: "Search SpringBoard instead of the app in front: system alerts, the home screen, Notification Center and the lock screen.")
    var springboard = false

    var query: AccessibilityQuery { AccessibilityQuery(label: label, identifier: identifier, role: role) }

    var isSet: Bool { !query.isEmpty }

    func validate() throws {
        if let index, index < 1 { throw ValidationError("--index counts from 1.") }
        if index != nil, query.isEmpty { throw ValidationError("--index needs --label, --id or --role.") }
    }

    /// The tree and what it takes to turn its frames into `tap` coordinates.
    struct Snapshot {
        var matches: [AccessibilityQuery.Match]
        var root: AccessibilityElement
        var orientation: DeviceOrientation

        /// Every labelled element on screen, as `ui-tree --labelled` prints it.
        var labelledLines: [String] {
            var lines: [String] = []
            func walk(_ element: AccessibilityElement) {
                if element.isLabelled, let center = element.normalizedCenter(in: root.frame, orientation: orientation) {
                    lines.append(element.line(center: center))
                }
                element.children.forEach(walk)
            }
            walk(root)
            return lines
        }
    }

    func snapshot(_ adapter: any SimulatorAdapter, udid: String) async throws -> Snapshot {
        let target: AccessibilityTarget = springboard
            ? .process(pid: try SimctlService().springBoardPID(udid: udid))
            : .frontmost
        let root = try adapter.accessibilityTree(udid, target: target)
        let orientation = try await DeviceOrientation.current(adapter, udid: udid)
        return Snapshot(
            matches: query.matches(in: root, screen: root.frame, orientation: orientation),
            root: root,
            orientation: orientation
        )
    }

    /// Polls the tree until exactly one element matches on screen, then returns it. A tree that
    /// cannot be read yet (the app still launching) is retried like one without a match.
    func find(_ adapter: any SimulatorAdapter, udid: String, timeout: Double) async throws -> AccessibilityQuery.Match {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var resolution: AccessibilityQuery.Resolution?
            var readError: (any Error)?
            var last: Snapshot?
            do {
                let snapshot = try await snapshot(adapter, udid: udid)
                last = snapshot
                resolution = query.resolve(snapshot.matches, index: index)
            } catch {
                readError = error
            }
            switch resolution {
            case .found(let match):
                return match
            case .ambiguous(let matches):
                // Waiting would not make several matches one.
                throw ElementError.ambiguous(query: query, matches: matches)
            case .indexOutOfRange(let matches):
                throw ElementError.indexOutOfRange(query: query, index: index ?? 0, matches: matches)
            case .notFound, .offScreen, nil:
                break
            }
            guard Date() < deadline else {
                if case .offScreen(let matches) = resolution {
                    throw ElementError.offScreen(query: query, matches: matches)
                }
                if let readError { throw readError }
                throw ElementError.notFound(query: query, timeout: timeout, onScreen: last?.labelledLines ?? [])
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}

enum ElementError: LocalizedError {
    case notFound(query: AccessibilityQuery, timeout: Double, onScreen: [String])
    case offScreen(query: AccessibilityQuery, matches: [AccessibilityQuery.Match])
    case ambiguous(query: AccessibilityQuery, matches: [AccessibilityQuery.Match])
    case indexOutOfRange(query: AccessibilityQuery, index: Int, matches: [AccessibilityQuery.Match])

    /// How many lines of the screen a not-found error shows, so it stays readable.
    private static let shownLines = 25

    var errorDescription: String? {
        switch self {
        case .notFound(let query, let timeout, let onScreen):
            let shown = onScreen.prefix(Self.shownLines).map { "  " + $0 }.joined(separator: "\n")
            let more = onScreen.count > Self.shownLines ? "\n  ... and \(onScreen.count - Self.shownLines) more" : ""
            return "Nothing matching \(query.summary) appeared within \(timeout) s. On screen now:\n\(shown)\(more)"
        case .offScreen(let query, let matches):
            let lines = matches.prefix(5).map { "  " + $0.line }.joined(separator: "\n")
            return "\(query.summary) is in the tree but off screen; scroll it into view first:\n\(lines)"
        case .ambiguous(let query, let matches):
            return "\(matches.count) elements match \(query.summary); pick one with --index or narrow it with --role or --id:\n"
                + Self.numbered(matches)
        case .indexOutOfRange(let query, let index, let matches):
            return "--index \(index) is out of range: \(matches.count) on screen match \(query.summary):\n" + Self.numbered(matches)
        }
    }

    private static func numbered(_ matches: [AccessibilityQuery.Match]) -> String {
        matches.enumerated().map { "  \($0.offset + 1). \($0.element.line)" }.joined(separator: "\n")
    }
}
