import CoreGraphics
import Testing
@testable import OpenDeviceHubEngine

struct NotificationBannerTests {
    let banner = NotificationBanner(
        label: "STUPID SOCIAL, now, Hello, World",
        frame: CGRect(x: 8, y: 58, width: 386, height: 66),
        screen: CGRect(x: 0, y: 0, width: 402, height: 874),
        actions: ["More", "Dismiss"]
    )

    @Test func matchesEveryExpectedPieceIgnoringCase() {
        #expect(banner.contains([]))
        #expect(banner.contains(["hello", "WORLD"]))
        #expect(!banner.contains(["Hello", "Modified"]))
    }

    @Test func itsCentreIsInTapCoordinates() throws {
        let centre = try #require(banner.normalizedCenter())
        #expect(abs(centre.x - 201.0 / 402) < 0.0001)
        #expect(abs(centre.y - 91.0 / 874) < 0.0001)
    }
}

struct LaunchctlListTests {
    let output = """
        PID\tStatus\tLabel
        -\t0\tcom.apple.progressd
        40784\t0\tcom.apple.SpringBoard
        40761\t0\tUIKitApplication:com.apple.SpringBoard.extra
        """

    @Test func findsARunningJobByItsExactLabel() {
        #expect(SimctlService.pid(ofJob: "com.apple.SpringBoard", inLaunchctlList: output) == 40784)
    }

    @Test func aJobThatIsNotRunningHasNoPid() {
        #expect(SimctlService.pid(ofJob: "com.apple.progressd", inLaunchctlList: output) == nil)
        #expect(SimctlService.pid(ofJob: "com.example.missing", inLaunchctlList: output) == nil)
    }

    @Test func theArgumentsAskTheGuestsLaunchd() {
        #expect(SimctlService.launchdJobsArguments(udid: "ABC") == ["simctl", "spawn", "ABC", "launchctl", "list"])
    }
}

struct ShownPointTests {
    @Test(arguments: DeviceOrientation.allCases)
    func undoesPortraitNativePoint(orientation: DeviceOrientation) {
        for shown in [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.75, y: 0.1), CGPoint(x: 0.5, y: 0.5)] {
            let native = CoordinateMapper.portraitNativePoint(from: shown, orientation: orientation)
            let back = CoordinateMapper.shownPoint(fromPortraitNative: native, orientation: orientation)
            #expect(abs(back.x - shown.x) < 0.0001 && abs(back.y - shown.y) < 0.0001)
        }
    }
}
