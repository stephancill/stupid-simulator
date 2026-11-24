import CoreGraphics
import Foundation
import Testing
@testable import OpenDeviceHubEngine

struct AppleTVTests {
    @Test func recognizesTVRuntimesOnly() {
        #expect(RuntimeIdentifier.isTV("com.apple.CoreSimulator.SimRuntime.tvOS-27-0"))
        #expect(!RuntimeIdentifier.isTV("com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        #expect(!RuntimeIdentifier.isTV("com.apple.CoreSimulator.SimRuntime.watchOS-11-0"))
        #expect(!RuntimeIdentifier.isTV(""))
    }

    @Test func findsARunningAppByBundleIdentifier() {
        let output = """
            PID\tStatus\tLabel
            99344\t0\tUIKitApplication:com.apple.TVSettings[5212][rb-legacy]
            98417\t0\tUIKitApplication:com.apple.HeadBoard[460d][rb-legacy]
            -\t0\tUIKitApplication:com.example.stopped[aaaa][rb-legacy]
            12369\t0\tUIKitApplication:com.apple.TVSettingsExtra[bbbb][rb-legacy]
            """
        #expect(SimctlService.pid(ofApplication: "com.apple.TVSettings", inLaunchctlList: output) == 99344)
        #expect(SimctlService.pid(ofApplication: "com.apple.HeadBoard", inLaunchctlList: output) == 98417)
        #expect(SimctlService.pid(ofApplication: "com.example.stopped", inLaunchctlList: output) == nil)
        #expect(SimctlService.pid(ofApplication: "com.example.missing", inLaunchctlList: output) == nil)
    }

    @Test func marksTheFocusedElementInItsLine() {
        var element = AccessibilityElement(
            role: "AXButton", roleDescription: "button", label: "Search", title: nil, identifier: nil,
            value: nil, frame: CGRect(x: 0, y: 0, width: 10, height: 10), children: []
        )
        #expect(element.line(center: nil) == "Button \"Search\"")
        element.focused = true
        #expect(element.line(center: CGPoint(x: 0.5, y: 0.25)) == "Button \"Search\" focused @ 0.50,0.25")
    }

    @Test func leavesFocusOutOfJSONUnlessSet() throws {
        let element = AccessibilityElement(
            role: "AXButton", roleDescription: nil, label: "Search", title: nil, identifier: nil,
            value: nil, frame: .zero, children: []
        )
        let json = String(decoding: try JSONEncoder().encode(element), as: UTF8.self)
        #expect(!json.contains("focused"))
    }

    @Test func refusesTouchAndReportsWhatToUseInstead() {
        let error = EngineError.unsupportedOnDevice(
            what: "Touch input",
            device: "Apple TV, which has no touchscreen",
            instead: "Use `stupidsim remote` to move focus and select."
        )
        #expect(error.localizedDescription
            == "Touch input is not supported on Apple TV, which has no touchscreen. Use `stupidsim remote` to move focus and select.")
    }
}
