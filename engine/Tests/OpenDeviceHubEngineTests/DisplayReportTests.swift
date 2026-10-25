import CoreGraphics
import Foundation
import Testing
import XPC
@testable import OpenDeviceHubEngine

@Suite struct DisplayReportParsingTests {
    private func record(
        id: String? = "A",
        deviceName: String? = nil,
        name: String = "LCD",
        displayID: Int64 = 1,
        active: Bool? = false,
        backlight: String? = "off",
        width: Double = 1398,
        height: Double = 2034,
        rotation: String = "rot90",
        integrated: Bool = true
    ) -> xpc_object_t {
        let entry = xpc_dictionary_create(nil, nil, 0)
        if let id { xpc_dictionary_set_string(entry, "uniqueId", id) }
        if let deviceName { xpc_dictionary_set_string(entry, "deviceName", deviceName) }
        xpc_dictionary_set_string(entry, "name", name)
        xpc_dictionary_set_int64(entry, "displayId", displayID)
        if let active { xpc_dictionary_set_bool(entry, "active", active) }
        if let backlight { xpc_dictionary_set_string(entry, "backlightState", backlight) }
        xpc_dictionary_set_bool(entry, "primary", displayID == 1)
        xpc_dictionary_set_int64(entry, "pointScale", 3)
        xpc_dictionary_set_string(entry, "currentOrientation", rotation)
        xpc_dictionary_set_string(entry, "nativeOrientation", "rot0")
        xpc_dictionary_set_string(entry, "chromeIdentifier", "com.apple.dt.devicekit.chrome.phone15")
        let bounds = xpc_array_create(nil, 0)
        for corner in [[0.0, 0.0], [width, height]] {
            let point = xpc_array_create(nil, 0)
            for value in corner { xpc_array_append_value(point, xpc_double_create(value)) }
            xpc_array_append_value(bounds, point)
        }
        xpc_dictionary_set_value(entry, "bounds", bounds)
        let type = xpc_dictionary_create(nil, nil, 0)
        if integrated { xpc_dictionary_set_value(type, "integrated", xpc_dictionary_create(nil, nil, 0)) }
        xpc_dictionary_set_value(entry, "type", type)
        return entry
    }

    private func output(current: Bool = true, backlight: String? = nil, _ records: [xpc_object_t]) -> xpc_object_t {
        let output = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(output, "current", current)
        if let backlight { xpc_dictionary_set_string(output, "backlightState", backlight) }
        let displays = xpc_array_create(nil, 0)
        for record in records { xpc_array_append_value(displays, record) }
        xpc_dictionary_set_value(output, "displays", displays)
        return output
    }

    @Test func readsAFoldableTheWayTheGuestWritesIt() throws {
        let report = try DisplayReport.parse(output([
            record(id: "cover", displayID: 1, active: false, backlight: "off"),
            record(id: "inner", name: "LCD-1", displayID: 3, active: true, backlight: "activeOn", width: 2007, height: 2853),
        ]))
        #expect(report.displays.count == 2)
        let active = try #require(report.activeIntegrated)
        #expect(active.uniqueID == "inner")
        #expect(active.displayID == 3)
        #expect(active.pixelSize == CGSize(width: 2007, height: 2853))
        #expect(active.currentRotation == 90)
        #expect(active.nativeRotation == 0)
        #expect(active.pointScale == 3)
        #expect(active.chromeIdentifier == "com.apple.dt.devicekit.chrome.phone15")
        #expect(report.display(withID: 1)?.isPrimary == true)
        #expect(report.display(withID: 1)?.isActive == false)
    }

    @Test func layoutIsTheAuthorityWhenTheReportCarriesIt() throws {
        // Backlight off on the active panel is odd but not contradictory; the layout wins.
        let report = try DisplayReport.parse(output([
            record(id: "a", displayID: 1, active: true, backlight: "off"),
        ]))
        #expect(report.activeIntegrated?.uniqueID == "a")
    }

    @Test func backlightDecidesWhenTheReportHasNoLayout() throws {
        let report = try DisplayReport.parse(output([
            record(id: "a", displayID: 1, active: nil, backlight: "inactiveOn"),
            record(id: "b", displayID: 3, active: nil, backlight: "activeDimmed"),
        ]))
        #expect(report.activeIntegrated?.uniqueID == "b")
    }

    @Test func refusesWhatDoesNotHoldTogether() {
        #expect(throws: (any Error).self) {
            try DisplayReport.parse(output(current: false, [record()]))
        }
        #expect(throws: (any Error).self) {
            try DisplayReport.parse(output([record(id: "same"), record(id: "same", displayID: 3)]))
        }
        #expect(throws: (any Error).self) {
            try DisplayReport.parse(output([record(active: true, backlight: "activeOn", width: 0, height: 0)]))
        }
    }

    @Test func onlyTheActivePanelsBacklightDecidesWhetherItIsSettled() throws {
        let lagging = try DisplayReport.parse(output([
            record(id: "cover", displayID: 1, active: false, backlight: "activeOn"),
            record(id: "inner", name: "LCD-1", displayID: 3, active: true, backlight: "activeOn", width: 2007, height: 2853),
        ]))
        #expect(lagging.activeIntegrated?.uniqueID == "inner")
        #expect(lagging.isSettled == true)
        let dark = try DisplayReport.parse(output([
            record(id: "cover", displayID: 1, active: true, backlight: "off"),
            record(id: "inner", name: "LCD-1", displayID: 3, active: false, backlight: "activeOn", width: 2007, height: 2853),
        ]))
        #expect(dark.isSettled == false)
    }

    @Test func onlyTheBuiltInScreensAreIntegrated() throws {
        let report = try DisplayReport.parse(output([
            record(id: "cover", displayID: 1, active: true, backlight: "activeOn"),
            record(id: "airplay", name: "AirPlay", displayID: 7, active: false, backlight: "off", integrated: false),
        ]))
        #expect(report.integrated.map(\.uniqueID) == ["cover"])
        #expect(report.displays.count == 2)
    }

    @Test func twoActiveScreensIsNoAnswer() throws {
        let report = try DisplayReport.parse(output([
            record(id: "a", displayID: 1, active: true, backlight: "activeOn"),
            record(id: "b", displayID: 3, active: true, backlight: "activeOn", width: 2007, height: 2853),
        ]))
        #expect(report.activeIntegrated == nil)
    }

    @Test func readsAPhoneThatWritesOneBacklightForTheDevice() throws {
        // As an iPhone 17 on iOS 27.0 reports it: no layout, no per display backlight, and the
        // TV out, wireless and resizable displays listed with no state of their own.
        let report = try DisplayReport.parse(output(backlight: "activeOn", [
            record(id: "lcd", displayID: 1, active: nil, backlight: nil, rotation: "rot0"),
            record(id: "tv", name: "TVOut", displayID: 2, active: nil, backlight: nil, integrated: false),
            record(id: "wireless", name: "Wireless", displayID: 3, active: nil, backlight: nil, integrated: false),
            record(id: "resizable", name: "Resizable", displayID: 4, active: nil, backlight: nil, integrated: false),
        ]))
        let active = try #require(report.activeIntegrated)
        #expect(active.uniqueID == "lcd")
        #expect(active.backlight == .activeOn)
        #expect(report.isSettled)
        #expect(report.displays.filter(\.isActive).count == 1)
    }

    @Test func namesADisplayByItsDeviceNameWhenItHasNoUniqueID() throws {
        // iOS 26 runtimes write no uniqueId at all.
        let report = try DisplayReport.parse(output(backlight: "activeOn", [
            record(id: nil, deviceName: "PurpleMain", displayID: 1, active: nil, backlight: nil),
            record(id: nil, deviceName: "PurpleTVOut", name: "TVOut", displayID: 2, active: nil, backlight: nil, integrated: false),
        ]))
        #expect(report.activeIntegrated?.uniqueID == "PurpleMain")
    }

    @Test func aBuiltInScreenWithNoStateIsStillNoAnswer() {
        #expect(throws: (any Error).self) {
            try DisplayReport.parse(output([record(active: nil, backlight: nil)]))
        }
        #expect(throws: (any Error).self) {
            try DisplayReport.parse(output([record(id: nil, active: nil, backlight: "activeOn")]))
        }
    }

    @Test func rotationsAreReadFromTheirNames() {
        #expect(DisplayReport.degrees("rot0") == 0)
        #expect(DisplayReport.degrees("rot90") == 90)
        #expect(DisplayReport.degrees("rot270") == 270)
        #expect(DisplayReport.degrees("sideways") == 0)
        #expect(DisplayReport.degrees(nil) == 0)
    }
}
