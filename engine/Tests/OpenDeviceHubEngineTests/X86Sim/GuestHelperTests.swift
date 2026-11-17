import Foundation
import Testing
@testable import OpenDeviceHubEngine

@Suite struct GuestHelperTests {
    @Test func theAnswerIsBetweenTheMarkers() throws {
        let output = """
            arm64host: jitcache: loaded 7467623 blocks
            @@stupidsim-guest-begin@@
            {"text" : "hi"}
            @@stupidsim-guest-end@@
            arm64host: jitcache: exit live save: 11174 descriptors
            """
        let json = try GuestHelper.answer(in: output, command: "pasteboard-get")
        #expect(String(decoding: json, as: UTF8.self) == #"{"text" : "hi"}"#)
    }

    @Test func aFailureIsThrownWithItsMessage() {
        let output = "@@stupidsim-guest-begin@@\n{\"error\" : \"no app is in front\"}\n@@stupidsim-guest-end@@\n"
        #expect(throws: X86SimError.guest(command: "tree", message: "no app is in front")) {
            try GuestHelper.answer(in: output, command: "tree")
        }
    }

    @Test func noAnswerShowsTheLastLines() {
        #expect(throws: X86SimError.self) { try GuestHelper.answer(in: "spawn: no such device\n", command: "tree") }
    }

    @Test func aTreeDecodesIntoTheSameElementsAsOnAMac() throws {
        let json = Data("""
            {"children":[{"children":[],"frame":[[283.3,66],[39.7,36]],"label":"Search","role":"AXButton",
             "roleDescription":"button","traits":8589934593,"identifier":"search"}],
             "frame":[[0,0],[402,874]],"label":"stupid social","pid":2743,"role":"AXApplication","roleDescription":"application"}
            """.utf8)
        let root = try JSONDecoder().decode(AccessibilityElement.self, from: json)
        #expect(root.role == "AXApplication")
        #expect(root.children.first?.label == "Search")
        #expect(root.children.first?.identifier == "search")
        #expect(root.children.first?.frame == CGRect(x: 283.3, y: 66, width: 39.7, height: 36))
    }

    @Test func aBannerDecodes() throws {
        let json = Data("""
            {"banner":{"actions":["More","Dismiss"],"frame":[[8,58.7],[386,66]],"label":"ODH TEST HOST, now, Hello",
             "screen":[[0,0],[402,874]]}}
            """.utf8)
        let banner = try #require(try JSONDecoder().decode(GuestHelper.BannerAnswer.self, from: json).banner)
        #expect(banner.actions == ["More", "Dismiss"])
        #expect(try JSONDecoder().decode(GuestHelper.BannerAnswer.self, from: Data(#"{"banner":null}"#.utf8)).banner == nil)
    }

    @Test func theProgramIsFoundBesideStupidsimOrInLibexec() {
        let executable = URL(fileURLWithPath: "/opt/stupidsim/bin/stupidsim")
        #expect(GuestHelper.candidates(environment: [:], executable: executable).map(\.path) == [
            "/opt/stupidsim/bin/stupidsim-guest",
            "/opt/stupidsim/libexec/stupidsim/stupidsim-guest",
        ])
        #expect(GuestHelper.candidates(environment: ["STUPIDSIM_GUEST": "/tmp/g"], executable: executable).map(\.path) == ["/tmp/g"])
    }
}
