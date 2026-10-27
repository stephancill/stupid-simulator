import OpenDeviceHubEngine

extension DeviceOrientation {
    /// The main screen's rotation now, which turns accessibility frames into `tap` coordinates.
    static func current(_ adapter: any SimulatorAdapter, udid: String) async throws -> DeviceOrientation {
        let report = try await adapter.displayReport(udid)
        // Accessibility's display 0 denotes the main screen; CoreDevice uses its own display IDs.
        guard report.isSettled, let display = report.activeIntegrated,
              let orientation = allCases.first(where: { $0.degrees == display.currentRotation }) else {
            throw EngineError.capabilityUnavailable(name: "the accessibility display's rotation")
        }
        return orientation
    }
}
