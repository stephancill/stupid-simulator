import CoreGraphics
import Foundation
import ImageIO

/// One screenshot as 32 bit pixels, for comparing frames rather than showing them.
public struct ScreenFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt32]

    public init(width: Int, height: Int, pixels: [UInt32]) {
        precondition(pixels.count == width * height, "a frame holds one value per pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Decodes a PNG, which is what `simctl io screenshot` writes.
    public init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EngineError.capabilityUnavailable(name: "decoding the screenshot")
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EngineError.capabilityUnavailable(name: "decoding the screenshot") }
        self.init(width: width, height: height, pixels: pixels)
    }
}

/// Whether input changed what the device shows. A screen that is already changing on its own, a
/// blinking cursor or a spinner, would make any comparison say yes, so the pixels that change
/// between frames taken before the input are left out of the count.
public enum ScreenChange {
    /// Below this many pixels a difference is treated as noise, not as the device responding.
    public static let minimumChangedPixels = 16

    /// The pixels that differ anywhere across `frames`, all taken before the input. Nil when the
    /// frames are not the same size, which means the screen turned while it was being watched.
    public static func noise(in frames: [ScreenFrame]) -> [Bool]? {
        guard let first = frames.first else { return nil }
        var mask = [Bool](repeating: false, count: first.pixels.count)
        for frame in frames.dropFirst() {
            guard frame.width == first.width, frame.height == first.height else { return nil }
            for index in mask.indices where frame.pixels[index] != first.pixels[index] {
                mask[index] = true
            }
        }
        return mask
    }

    public struct Difference: Sendable, Equatable {
        public let pixels: Int
        /// The smallest rectangle, in screenshot pixels, holding every changed pixel.
        public let bounds: CGRect

        public var isChange: Bool { pixels >= ScreenChange.minimumChangedPixels }
    }

    /// The pixels outside `noise` that differ between the two frames. A change of size, from the
    /// device turning, counts as every pixel.
    public static func difference(from before: ScreenFrame, to after: ScreenFrame, ignoring noise: [Bool]) -> Difference {
        guard before.width == after.width, before.height == after.height, noise.count == before.pixels.count else {
            return Difference(
                pixels: max(before.pixels.count, after.pixels.count),
                bounds: CGRect(x: 0, y: 0, width: after.width, height: after.height)
            )
        }
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for index in before.pixels.indices where !noise[index] && before.pixels[index] != after.pixels[index] {
            changed += 1
            let x = index % before.width
            let y = index / before.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let bounds = changed == 0
            ? CGRect.zero
            : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Difference(pixels: changed, bounds: bounds)
    }
}
