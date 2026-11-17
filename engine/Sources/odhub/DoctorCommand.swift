import ArgumentParser
import Foundation
import OpenDeviceHubEngine

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report the active Xcode (on Linux, x86Sim), the simulator frameworks and what resolves from them."
    )

    #if os(macOS)
    func run() throws {
        let install = try XcodeLocator.locate()

        print("Xcode")
        print("  version:       \(install.version) (\(install.build))")
        print("  developer dir: \(display(install.developerDir))")
        print("  app root:      \(display(install.appRoot))")
        if let advisory = AdapterFactory.advisory(for: install.version) {
            print("  warning:       \(advisory)")
        }

        var loadFailed = false
        for framework in PrivateFramework.allCases {
            print("")
            print(framework.rawValue)
            do {
                let loaded = try FrameworkLoader.load(framework, from: install)
                print("  loaded: \(loaded.path)")
                report(PrivateSymbolProbe.probeAll(in: framework))
            } catch let error as EngineError {
                loadFailed = true
                print("  not loaded: \(error.localizedDescription)")
            }
        }

        print("")
        print("Device bodies")
        reportChrome()

        if loadFailed {
            throw ExitCode.failure
        }
    }

    /// The body artwork lives outside Xcode, in DeviceKit, so it is reported separately: a missing
    /// bundle is not a broken install, it only means a device keeps the plain masked screen.
    private func reportChrome() {
        let directory = URL(fileURLWithPath: ChromeLocator.chromeDirectory)
        let bundles = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "devicechrome" } ?? []
        guard !bundles.isEmpty else {
            print("  none found in \(ChromeLocator.chromeDirectory)")
            return
        }
        print("  \(bundles.count) in \(ChromeLocator.chromeDirectory)")

        let adapter = try? AdapterFactory.make(for: XcodeLocator.locate())
        let devices = (try? adapter?.devices()) ?? []
        let booted = devices.filter { $0.state == .booted }
        let shown = booted.isEmpty ? Array(devices.prefix(3)) : booted
        for device in shown {
            let type = device.deviceTypeIdentifier
            if let chrome = ChromeLocator.chrome(forDeviceType: type) {
                let buttons = chrome.buttons.map(\.name).joined(separator: ", ")
                print("  ok      \(device.name): \(chrome.identifier)")
                print("          body \(Int(chrome.insets.left))pt, buttons: \(buttons)")
            } else {
                print("  missing \(device.name): no body for \(type)")
            }
        }
    }

    private func display(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func report(_ results: [SymbolProbeResult]) {
        let width = results.map(\.requested.count).max() ?? 0
        for result in results {
            guard let resolved = result.resolved else {
                let name = result.requested.padding(toLength: width, withPad: " ", startingAt: 0)
                print("  missing \(name)  \(result.kind.rawValue)")
                continue
            }
            let name = result.requested.padding(toLength: width, withPad: " ", startingAt: 0)
            if resolved == result.requested {
                print("  ok      \(name)  \(result.kind.rawValue)")
            } else {
                print("  ok      \(name)  \(result.kind.rawValue) (as \(resolved))")
            }
        }
    }
    #else
    func run() throws {
        let install: X86SimInstall
        do {
            install = try X86SimInstall.locate()
        } catch {
            print("x86Sim")
            print("  not found: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        var failed = false

        print("x86Sim")
        print("  launcher: \(install.launcher.path)")
        do {
            print("  version:  \(try install.version())")
        } catch {
            failed = true
            print("  version:  unreadable: \(error.localizedDescription)")
        }
        print("  data:     \(install.dataRoot.path)")

        print("")
        print(GuestHelper.programName)
        do {
            print("  found:    \(try GuestHelper(install: install).program.path)")
        } catch {
            failed = true
            print("  missing:  \(error.localizedDescription)")
        }

        print("")
        print("Devices")
        let devices = try install.devices()
        if devices.isEmpty {
            print("  none: create one with `x86sim device create --model \"iPhone 17 Pro\" <name>`")
        }
        for device in devices {
            let booted = device.isBooted
            print("  \(booted ? "booted  " : "shutdown") \(device.name): \(device.model), \(device.runtimeName), \(device.udid)")
            guard booted else { continue }
            do {
                let frame = try FrameRing.latest(at: device.frameRing)
                print("           frames: \(frame.width)x\(frame.height) from \(device.frameRing.path)")
            } catch {
                failed = true
                print("           frames: \(error.localizedDescription)")
            }
        }
        if failed {
            throw ExitCode.failure
        }
    }
    #endif
}
