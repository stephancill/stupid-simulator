import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OpenDeviceHubEngine

@Suite struct ScreenChangeTests {
    private func frame(_ width: Int = 4, _ height: Int = 4, painting points: [(Int, Int)] = []) -> ScreenFrame {
        var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        for (x, y) in points { pixels[y * width + x] = 0xFFFF_FFFF }
        return ScreenFrame(width: width, height: height, pixels: pixels)
    }

    @Test func aStillScreenHasNoNoise() throws {
        let noise = try #require(ScreenChange.noise(in: [frame(), frame(), frame()]))
        #expect(!noise.contains(true))
    }

    @Test func noiseIsEveryPixelThatChangedBetweenAnyTwoFrames() throws {
        // A cursor on in the first frame, off in the second, on again in the third.
        let cursor = [(1, 1), (1, 2)]
        let noise = try #require(ScreenChange.noise(in: [frame(painting: cursor), frame(), frame(painting: cursor)]))
        #expect(noise.enumerated().filter(\.element).map(\.offset) == [5, 9])
    }

    @Test func framesOfDifferentSizesHaveNoNoiseToSpeakOf() {
        #expect(ScreenChange.noise(in: [frame(4, 4), frame(4, 5)]) == nil)
    }

    @Test func aChangeInsideTheNoiseIsNotCounted() throws {
        let cursor = [(1, 1)]
        let noise = try #require(ScreenChange.noise(in: [frame(painting: cursor), frame()]))
        let difference = ScreenChange.difference(from: frame(), to: frame(painting: cursor), ignoring: noise)
        #expect(difference.pixels == 0)
        #expect(!difference.isChange)
    }

    @Test func aChangeOutsideTheNoiseIsCountedAndBoxed() throws {
        let noise = [Bool](repeating: false, count: 64 * 64)
        let typed = (10..<14).flatMap { x in (20..<25).map { y in (x, y) } }
        let difference = ScreenChange.difference(from: frame(64, 64), to: frame(64, 64, painting: typed), ignoring: noise)
        #expect(difference.pixels == 20)
        #expect(difference.isChange)
        #expect(difference.bounds == CGRect(x: 10, y: 20, width: 4, height: 5))
    }

    @Test func aFewStrayPixelsAreNotAChange() {
        let noise = [Bool](repeating: false, count: 16)
        let difference = ScreenChange.difference(from: frame(), to: frame(painting: [(0, 0), (3, 3)]), ignoring: noise)
        #expect(difference.pixels == 2)
        #expect(!difference.isChange)
    }

    @Test func turningTheScreenIsAChangeOfEveryPixel() {
        let noise = [Bool](repeating: false, count: 16)
        let difference = ScreenChange.difference(from: frame(4, 4), to: frame(2, 8), ignoring: noise)
        #expect(difference.pixels == 16)
        #expect(difference.isChange)
    }

    @Test func decodesAPNG() throws {
        let png = try #require(Self.png(width: 3, height: 2))
        let decoded = try ScreenFrame(png: png)
        #expect(decoded.width == 3)
        #expect(decoded.height == 2)
        #expect(decoded == (try ScreenFrame(png: png)), "decoding the same picture twice gives the same pixels")
    }

    @Test func refusesDataThatIsNotAPicture() {
        #expect(throws: (any Error).self) { try ScreenFrame(png: Data("not a png".utf8)) }
    }

    private static func png(width: Int, height: Int) -> Data? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
