import Foundation
import Testing
@testable import OpenDeviceHubViewer

/// Two `DeviceWindowClaims` in one process stand in for two viewer processes: each opens its own
/// descriptor, and `flock` locks belong to the descriptor, so they refuse each other the same way.
@MainActor
struct DeviceWindowClaimsTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "claims-\(UUID().uuidString)")

    @Test func aSecondViewerIsRefusedAndToldWhoHasTheDevice() throws {
        let first = DeviceWindowClaims(directory: directory)
        let second = DeviceWindowClaims(directory: directory)
        try first.claim("ABC")
        #expect(throws: DeviceWindowError.openElsewhere(udid: "ABC", pid: getpid())) {
            try second.claim("ABC")
        }
    }

    @Test func releasingLetsAnotherViewerTakeIt() throws {
        let first = DeviceWindowClaims(directory: directory)
        let second = DeviceWindowClaims(directory: directory)
        try first.claim("ABC")
        first.release("ABC")
        try second.claim("ABC")
        #expect(second.holds("ABC"))
    }

    @Test func claimingAgainInTheSameViewerSucceeds() throws {
        let claims = DeviceWindowClaims(directory: directory)
        try claims.claim("ABC")
        try claims.claim("abc")
        #expect(claims.holds("ABC"))
    }

    @Test func otherDevicesAreUnaffected() throws {
        let first = DeviceWindowClaims(directory: directory)
        let second = DeviceWindowClaims(directory: directory)
        try first.claim("ABC")
        try second.claim("DEF")
    }

    @Test func theManagerLetsGoOfAClaimWhenNoWindowOpened() throws {
        let claims = DeviceWindowClaims(directory: directory)
        let manager = DeviceWindowManager(
            frameStore: WindowFrameStore(storage: InMemoryPreferences(), prefix: "test."),
            settings: ViewerSettings(storage: InMemoryPreferences(), prefix: "test."),
            claims: claims,
            shutdown: { _ in }
        )
        try manager.claim("ABC")
        manager.releaseClaim("ABC")
        try DeviceWindowClaims(directory: directory).claim("ABC")
    }
}
