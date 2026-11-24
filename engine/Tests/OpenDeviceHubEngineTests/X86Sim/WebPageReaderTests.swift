import CoreGraphics
import Foundation
import Testing
@testable import OpenDeviceHubEngine

@Suite struct WebPageReaderTests {
    private func temporary(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A device directory with the sim.env X86SimDevice needs, and the reader's directory in it.
    private func device(udid: String = "375A691D-3C91-53B7-9F8B-74A8344FC281") throws -> (X86SimDevice, URL) {
        let root = try temporary("webax-device")
        try "SIMULATOR_UDID=\(udid)\n".write(to: root.appending(path: "sim.env"), atomically: true, encoding: .utf8)
        let device = try X86SimDevice(directory: root)
        let web = device.dataDirectory.appending(path: "tmp/stupidsim-web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        return (device, web)
    }

    private func element(_ label: String, _ frame: CGRect) -> AccessibilityElement {
        AccessibilityElement(role: "AXStaticText", roleDescription: "text", label: label, title: nil, identifier: nil,
                             value: nil, frame: frame, children: [])
    }

    @Test func onlyProcessesWithAPageOfTheAppInFrontAreAsked() throws {
        let (device, web) = try device()
        try "8445\n".write(to: web.appending(path: "pages-8037"), atomically: true, encoding: .utf8)
        try "".write(to: web.appending(path: "pages-8139"), atomically: true, encoding: .utf8)  // no pages
        try "9000\n8445\n".write(to: web.appending(path: "pages-8200"), atomically: true, encoding: .utf8)
        try "9000\n".write(to: web.appending(path: "pages-8300"), atomically: true, encoding: .utf8)  // another app
        try "x".write(to: web.appending(path: "web-8037.json"), atomically: true, encoding: .utf8)
        #expect(WebPageReader(device: device).processes(hosting: 8445) == [8037, 8200])
    }

    /// pages-<pid> outlives its process; only this device's running WebContent counts.
    @Test func aProcessIsLiveWhenThisDevicesWebContentRunsAsThatPID() throws {
        let (device, _) = try device()
        let proc = try temporary("webax-proc")
        func process(_ pid: Int, inner: Int, argv0: String, udid: String) throws {
            let directory = proc.appending(path: String(pid))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Name:\tx\nNSpid:\t\(pid)\t\(inner)\n".write(to: directory.appending(path: "status"), atomically: true, encoding: .utf8)
            try Data((argv0 + "\0").utf8).write(to: directory.appending(path: "cmdline"))
            try Data("HOME=/x\0SIMULATOR_UDID=\(udid)\0".utf8).write(to: directory.appending(path: "environ"))
        }
        let webContent = "/Volumes/SystemRoot/x/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc/com.apple.WebKit.WebContent"
        try process(51591, inner: 8037, argv0: webContent, udid: device.udid)
        try process(51600, inner: 8200, argv0: webContent, udid: "OTHER-DEVICE")
        try process(51700, inner: 8300, argv0: "/x/MobileSafari", udid: device.udid)
        var reader = WebPageReader(device: device)
        reader.proc = proc.path
        #expect(reader.livePIDs(among: [8037, 8200, 8300, 8400]) == [8037])
    }

    @Test func theAppsPagesAreMergedOnceAndOnlyOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
        let text = element("This domain is for use in documentation", CGRect(x: 32, y: 269, width: 338, height: 98))
        let link = element("Learn more", CGRect(x: 160, y: 860, width: 82, height: 21))
        let below = element("Below the screen", CGRect(x: 32, y: 900, width: 338, height: 40))
        let otherApp = element("Another app's page", CGRect(x: 32, y: 100, width: 338, height: 40))
        let answers = [
            WebPageReader.Answer(request: "a", pages: [.init(host: 8445, elements: [text, link, below])]),
            WebPageReader.Answer(request: "b", pages: [.init(host: 8445, elements: [text]), .init(host: 9000, elements: [otherApp])]),
        ]
        #expect(WebPageReader.merge(answers, hostPID: 8445, screen: screen).map(\.label) == [text.label, link.label])
    }

    @Test func anAnswerDecodesFromTheLibrarysJSON() throws {
        let json = #"""
            {"pid":8037,"request":"T","pages":[{"host":8445,"elements":[{"frame":[[160,860],[82,21]],"label":"Learn more",
            "role":"AXLink","roleDescription":"link","traits":2,"children":[]}]}]}
            """#
        let answer = try JSONDecoder().decode(WebPageReader.Answer.self, from: Data(json.utf8))
        #expect(answer.request == "T")
        #expect(answer.pages.first?.elements.first?.role == "AXLink")
        #expect(answer.pages.first?.elements.first?.frame == CGRect(x: 160, y: 860, width: 82, height: 21))
    }
}
