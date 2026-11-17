import CoreGraphics
import Foundation
import Testing
@testable import OpenDeviceHubEngine

private let screen = CGRect(x: 0, y: 0, width: 400, height: 800)

private func element(
    _ role: String,
    _ label: String? = nil,
    id: String? = nil,
    at frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40),
    children: [AccessibilityElement] = []
) -> AccessibilityElement {
    AccessibilityElement(
        role: "AX" + role, roleDescription: nil, label: label, title: nil, identifier: id, value: nil,
        frame: frame, children: children
    )
}

private func tree(_ children: [AccessibilityElement]) -> AccessibilityElement {
    element("Application", "App", at: screen, children: children)
}

@Suite struct AccessibilityQueryTests {
    @Test func exactLabelWinsOverSubstrings() {
        let root = tree([
            element("Button", "Send later", at: CGRect(x: 0, y: 100, width: 100, height: 40)),
            element("Button", "Send", at: CGRect(x: 0, y: 700, width: 100, height: 40)),
        ])
        let query = AccessibilityQuery(label: "Send")
        guard case .found(let match) = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected one match"); return
        }
        #expect(match.element.label == "Send")
        #expect(match.line == "Button \"Send\" @ 0.12,0.90")
    }

    @Test func substringMatchIgnoresCase() {
        let root = tree([element("Button", "Telegram, Saved Messages, 2 unread", at: CGRect(x: 0, y: 200, width: 400, height: 60))])
        let query = AccessibilityQuery(label: "saved messages")
        guard case .found = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected a substring match"); return
        }
    }

    @Test func severalOnScreenAreAmbiguousUntilIndexed() {
        let root = tree([
            element("Button", "Reply", at: CGRect(x: 0, y: 100, width: 100, height: 40)),
            element("Button", "Reply", at: CGRect(x: 0, y: 300, width: 100, height: 40)),
        ])
        let query = AccessibilityQuery(label: "Reply")
        let matches = query.matches(in: root, screen: screen)
        guard case .ambiguous(let all) = query.resolve(matches) else { Issue.record("expected ambiguous"); return }
        #expect(all.count == 2)
        guard case .found(let second) = query.resolve(matches, index: 2) else { Issue.record("expected --index 2"); return }
        #expect(second.element.frame.minY == 300)
        guard case .indexOutOfRange = query.resolve(matches, index: 3) else { Issue.record("expected out of range"); return }
    }

    @Test func aCellAndItsOwnTextCountAsOne() {
        let frame = CGRect(x: 0, y: 100, width: 400, height: 60)
        let root = tree([element("Cell", "Inbox", at: frame, children: [element("StaticText", "Inbox", at: frame)])])
        let query = AccessibilityQuery(label: "Inbox")
        guard case .found(let match) = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected the duplicates to collapse"); return
        }
        #expect(match.element.displayRole == "Cell")
    }

    @Test func offScreenMatchesAreIgnoredWhenOneIsOnScreen() {
        let root = tree([
            element("Button", "Like", at: CGRect(x: 0, y: -200, width: 100, height: 40)),
            element("Button", "Like", at: CGRect(x: 0, y: 400, width: 100, height: 40)),
        ])
        let query = AccessibilityQuery(label: "Like")
        guard case .found(let match) = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected the on-screen match"); return
        }
        #expect(match.element.frame.minY == 400)
    }

    @Test func onlyOffScreenMatchesSaySo() {
        let root = tree([element("Button", "Load more", at: CGRect(x: 0, y: 1200, width: 100, height: 40))])
        let query = AccessibilityQuery(label: "Load more")
        guard case .offScreen = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected offScreen"); return
        }
        #expect(query.resolve([]) == .notFound)
    }

    @Test func theAppItselfIsNotAMatch() {
        let root = tree([element("Button", "App", id: "BackButton", at: CGRect(x: 0, y: 50, width: 60, height: 40))])
        let query = AccessibilityQuery(label: "App")
        guard case .found(let match) = query.resolve(query.matches(in: root, screen: screen)) else {
            Issue.record("expected only the Back button"); return
        }
        #expect(match.element.identifier == "BackButton")
    }

    @Test func roleAndIdentifierNarrowTheMatch() {
        let root = tree([
            element("StaticText", "Search", at: CGRect(x: 0, y: 50, width: 100, height: 40)),
            element("TextField", "Search", id: "URL", at: CGRect(x: 0, y: 750, width: 400, height: 40)),
        ])
        for query in [AccessibilityQuery(label: "Search", role: "textfield"), AccessibilityQuery(identifier: "URL")] {
            guard case .found(let match) = query.resolve(query.matches(in: root, screen: screen)) else {
                Issue.record("expected one match for \(query.summary)"); continue
            }
            #expect(match.element.displayRole == "TextField")
        }
    }
}

@Suite struct DeviceArgumentNormalizerTests {
    private let commands: Set<String> = ["tap", "type", "screenshot"]
    private let udid = "591E7BBD-5074-42E0-98F8-6E5FBE4EC96E"

    private func normalize(_ arguments: [String], environment: [String: String] = [:]) -> [String] {
        DeviceArgumentNormalizer.normalize(arguments, deviceCommands: commands, environment: environment)
    }

    @Test func leavesAGivenDeviceAlone() {
        #expect(normalize(["tap", udid, "--x", "0.5", "--y", "0.5"]) == ["tap", udid, "--x", "0.5", "--y", "0.5"])
        #expect(normalize(["tap", "--x", "0.5", "--y", "0.5", udid]) == ["tap", "--x", "0.5", "--y", "0.5", udid])
        #expect(normalize(["tap", "booted", "--label", "Send"]) == ["tap", "booted", "--label", "Send"])
    }

    @Test func movesTheUdidOptionToTheFront() {
        #expect(normalize(["type", "hello", "--udid", udid]) == ["type", udid, "hello"])
        #expect(normalize(["type", "--udid=\(udid)", "hello"]) == ["type", udid, "hello"])
    }

    @Test func fillsInAMissingDevice() {
        #expect(normalize(["type", "hello"]) == ["type", "booted", "hello"])
        #expect(normalize(["screenshot", "out.png"], environment: ["STUPIDSIM_UDID": udid]) == ["screenshot", udid, "out.png"])
        #expect(normalize(["tap", "--help"]) == ["tap", "booted", "--help"])
    }

    @Test func leavesOtherCommandsAlone() {
        #expect(normalize(["list"]) == ["list"])
        #expect(normalize(["help", "tap"]) == ["help", "tap"])
        #expect(normalize([]) == [])
    }

    @Test func leavesAMissingUdidValueForTheParser() {
        #expect(normalize(["tap", "--udid"]) == ["tap", "--udid"])
    }
}
