#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// Screenshots read straight from the main display's framebuffer surface.
///
/// `simctl io screenshot` asks the guest for the picture, and the guest takes the Dynamic Island
/// out of its framebuffer for about 170 ms while it does, so every screenshot made the island
/// blink in any window or recording showing the device. Reading the surface the display session
/// already shares involves the guest not at all. Verified on Xcode 27 (27A266a), iOS 27.0.
public enum FramebufferCapture {
    /// The current frame of the device's main display, without the bezel mask: the full
    /// rectangle, as `simctl io screenshot` saved it, but with the island drawn where it is.
    public static func image(adapter: any SimulatorAdapter, udid: String) throws -> CGImage {
        let session = try adapter.openDisplay(udid)
        defer { session.close() }
        // The session sends the current frame as it opens and again when the bezel changes; the
        // stream keeps only the newest, so after this it holds the unmasked frame.
        session.setBezelEnabled(false)

        let box = SurfaceBox()
        let arrived = DispatchSemaphore(value: 0)
        let task = Task {
            for await frame in session.frames {
                box.surface = frame.surface
                arrived.signal()
                return
            }
        }
        defer { task.cancel() }
        guard arrived.wait(timeout: .now() + 5) == .success, let surface = box.surface else {
            throw EngineError.capabilityUnavailable(name: "a frame from \(udid)'s display")
        }
        guard let image = image(from: surface) else {
            throw EngineError.capabilityUnavailable(name: "reading \(udid)'s framebuffer")
        }
        return image
    }

    public static func png(adapter: any SimulatorAdapter, udid: String) throws -> Data {
        try png(from: image(adapter: adapter, udid: udid))
    }

    /// Copies a framebuffer surface into an image. Copied rather than wrapped, because the surface
    /// keeps being drawn into and a lazily read provider would show a later frame or tear.
    public static func image(from surface: IOSurfaceRef) -> CGImage? {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    public static func png(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw EngineError.capabilityUnavailable(name: "a PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EngineError.capabilityUnavailable(name: "encoding the screenshot as PNG")
        }
        return output as Data
    }
}

private final class SurfaceBox: @unchecked Sendable {
    var surface: IOSurfaceRef?
}
#endif
