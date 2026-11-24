// swift-tools-version: 6.0
import Foundation
import PackageDescription

#if os(Linux)
// On Linux only the command line builds, driving x86Sim's simulators (Host/X86Sim). The engine's
// sources are listed rather than excluded, so a file added upstream never breaks this build: the
// rest of the engine is CoreSimulator, AppKit and Metal.
let portableEngineSources = [
    "Brand.swift",
    "Errors.swift",
    "Adapter/AccessibilityQuery.swift",
    "Adapter/AccessibilityTree.swift",
    "Adapter/NotificationBanner.swift",
    "Adapter/SimulatorAdapter.swift",
    "Devices/RuntimeIdentifier.swift",
    "Host",
    "Input/CoordinateMapper.swift",
    "Input/DeviceOrientation.swift",
    "Input/HomeGesture.swift",
    "Input/KeyboardMap.swift",
    "Input/ScreenEdge.swift",
    "Input/SystemGesture.swift",
    "Input/TouchPath.swift",
    "Input/TwoFingerGesture.swift",
    "Support/DeviceArgumentNormalizer.swift",
    "Support/ExecutableLocator.swift",
    "Support/ProcessRunner.swift",
    "Support/ScreenChange.swift",
]

let portableEngineTests = [
    "AccessibilityQueryTests.swift",
    "CoordinateMapperTests.swift",
    "ExecutableLocatorTests.swift",
    "KeyboardMapTests.swift",
    "KeyChordTests.swift",
    "SystemGestureTests.swift",
    "TouchPathTests.swift",
    "TwoFingerGestureTests.swift",
    "X86Sim",
]

/// Everything in a target's directory that is not listed, so SwiftPM does not warn about each
/// macOS file it leaves out.
func unlisted(in directory: String, keeping listed: [String]) -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(directory)
    guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
    var excluded: [String] = []
    for case let path as String in walker {
        let kept = listed.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory)
        if !kept, !isDirectory.boolValue { excluded.append(path) }
    }
    return excluded
}

let package = Package(
    name: "OpenDeviceHub",
    products: [
        .executable(name: "stupidsim", targets: ["odhub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Foundation already has CGFloat, CGPoint, CGSize and CGRect on Linux; this module lets the
        // engine's `import CoreGraphics` lines stand unchanged.
        .target(name: "CoreGraphics", path: "Linux/CoreGraphics"),
        .target(name: "CZlib", linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "OpenDeviceHubEngine",
            dependencies: ["CoreGraphics", "CZlib"],
            exclude: unlisted(in: "Sources/OpenDeviceHubEngine", keeping: portableEngineSources),
            sources: portableEngineSources
        ),
        .executableTarget(
            name: "odhub",
            dependencies: [
                "CoreGraphics",
                "OpenDeviceHubEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "OpenDeviceHubEngineTests",
            dependencies: ["CoreGraphics", "OpenDeviceHubEngine"],
            exclude: unlisted(in: "Tests/OpenDeviceHubEngineTests", keeping: portableEngineTests),
            sources: portableEngineTests
        ),
    ],
    swiftLanguageModes: [.v6]
)
#else
let package = Package(
    name: "OpenDeviceHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenDeviceHubEngine", targets: ["OpenDeviceHubEngine"]),
        .library(name: "OpenDeviceHubViewer", targets: ["OpenDeviceHubViewer"]),
        .executable(name: "stupidsim", targets: ["odhub"]),
        .executable(name: "stupidsim-viewer", targets: ["ODHubViewerApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "OpenDeviceHubPrivate"),
        // zlib for the PNGs Host/X86Sim writes, built on the Mac too so its tests run here.
        .target(name: "CZlib", linkerSettings: [.linkedLibrary("z")]),
        .target(
            name: "OpenDeviceHubEngine",
            dependencies: ["OpenDeviceHubPrivate", "CZlib"]
        ),
        .target(
            name: "OpenDeviceHubViewer",
            dependencies: [
                "OpenDeviceHubEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "odhub",
            dependencies: [
                "OpenDeviceHubEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ODHubViewerApp",
            dependencies: [
                "OpenDeviceHubEngine",
                "OpenDeviceHubViewer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "OpenDeviceHubEngineTests",
            dependencies: ["OpenDeviceHubEngine"]
        ),
        .testTarget(
            name: "OpenDeviceHubViewerTests",
            dependencies: ["OpenDeviceHubViewer"]
        ),
        .testTarget(
            name: "OpenDeviceHubIntegrationTests",
            dependencies: ["OpenDeviceHubEngine", "OpenDeviceHubViewer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
#endif
