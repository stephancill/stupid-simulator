import Foundation
import Testing
@testable import OpenDeviceHubEngine

@Suite struct X86SimDeviceTests {
    private func dataRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "x86sim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "var"), withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func device(in root: URL, directory: String, name: String?, udid: String?) throws -> URL {
        let folder = root.appending(path: "var/\(directory)")
        try FileManager.default.createDirectory(at: folder.appending(path: "data"), withIntermediateDirectories: true)
        if let name { try "\(name)\n".write(to: folder.appending(path: "name"), atomically: true, encoding: .utf8) }
        try "iPhone 17 Pro\n".write(to: folder.appending(path: "model"), atomically: true, encoding: .utf8)
        try "ios-27.2-24B8117-arm64\n".write(to: folder.appending(path: "runtime"), atomically: true, encoding: .utf8)
        var environment = """
            HOME=/Volumes/SystemRoot/x/data
            SIMULATOR_MAINSCREEN_WIDTH=1206
            SIMULATOR_MAINSCREEN_HEIGHT=2622
            SIMULATOR_MAINSCREEN_SCALE=3.000000
            SIMULATOR_VERSION_INFO=x86Sim - Device: x86sim (ABC) - Runtime: iOS 27.2 (24B8117)

            """
        if let udid { environment += "SIMULATOR_UDID=\(udid)\n" }
        try environment.write(to: folder.appending(path: "sim.env"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func readsADevicesDirectory() throws {
        let root = try dataRoot()
        let folder = try device(in: root, directory: "device-a64-ss", name: "ss", udid: "75E9E25B-775D-5E63-8AC4-1E7656FF7D13")
        let device = try X86SimDevice(directory: folder)
        #expect(device.name == "ss")
        #expect(device.model == "iPhone 17 Pro")
        #expect(device.udid == "75E9E25B-775D-5E63-8AC4-1E7656FF7D13")
        #expect(device.runtimeName == "iOS 27.2")
        #expect(device.screenPixels == CGSize(width: 1206, height: 2622))
        #expect(device.scale == 3)
        #expect(device.frameRing.path == "/dev/shm/x86sim-a64-ss-simfb.ring")
        #expect(device.inputSocket == folder.appending(path: "data/simhid.sock"))
    }

    @Test func theDefaultDevicesRingHasNoName() throws {
        let root = try dataRoot()
        let device = try X86SimDevice(directory: device(in: root, directory: "device-a64", name: nil, udid: "AAAA"))
        #expect(device.frameRing.path == "/dev/shm/x86sim-a64-simfb.ring")
        #expect(device.name == "default")
    }

    @Test func aDeviceWithoutAUDIDIsUnreadable() throws {
        let root = try dataRoot()
        let folder = try device(in: root, directory: "device-a64-x", name: "x", udid: nil)
        #expect(throws: X86SimError.self) { try X86SimDevice(directory: folder) }
    }

    @Test func listsFinishedDevicesInNameOrder() throws {
        let root = try dataRoot()
        try device(in: root, directory: "device-a64-zed", name: "zed", udid: "B")
        try device(in: root, directory: "device-a64-alpha", name: "alpha", udid: "A")
        // Being created: no sim.env yet.
        try FileManager.default.createDirectory(at: root.appending(path: "var/device-a64-new"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "var/metal"), withIntermediateDirectories: true)
        let devices = try X86SimDevice.all(in: root)
        #expect(devices.map(\.name) == ["alpha", "zed"])
    }

    @Test func aDeviceWithNoInputSocketIsShutDown() throws {
        let root = try dataRoot()
        let info = try X86SimDevice(directory: device(in: root, directory: "device-a64-ss", name: "ss", udid: "C")).info()
        #expect(info.state == .shutdown)
        #expect(info.runtimeName == "iOS 27.2")
        #expect(info.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        #expect(info.deviceTypeIdentifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
    }

    @Test func environmentLinesSplitAtTheFirstEquals() {
        let values = X86SimDevice.parseEnvironment("A=1\n# B=2\nPATH=/a=b:/c\n\nbroken\n")
        #expect(values == ["A": "1", "PATH": "/a=b:/c"])
    }

    @Test func theLauncherVariableWinsEvenWhenMissing() {
        let home = URL(fileURLWithPath: "/home/someone")
        #expect(X86SimInstall.launcherCandidates(environment: ["STUPIDSIM_X86SIM": "/opt/x.AppImage"], home: home).map(\.path) == ["/opt/x.AppImage"])
        #expect(X86SimInstall.launcherCandidates(environment: [:], home: home).map(\.path) == ["/home/someone/.local/share/stupidsim/x86sim/AppRun"])
        #expect(X86SimInstall.launcherCandidates(environment: ["XDG_DATA_HOME": "/data"], home: home).map(\.path) == ["/data/stupidsim/x86sim/AppRun"])
    }

    @Test func theDataDirectoryFollowsX86SimsOwnRules() {
        let home = URL(fileURLWithPath: "/home/someone")
        #expect(X86SimInstall.dataRoot(environment: [:], home: home).path == "/home/someone/.local/share/x86sim")
        #expect(X86SimInstall.dataRoot(environment: ["XDG_DATA_HOME": "/data"], home: home).path == "/data/x86sim")
        #expect(X86SimInstall.dataRoot(environment: ["X86SIM_DATA": "/x", "XDG_DATA_HOME": "/data"], home: home).path == "/x")
    }
}
