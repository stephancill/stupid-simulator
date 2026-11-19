import Foundation
import Testing
@testable import OpenDeviceHubEngine
#if canImport(ImageIO)
import ImageIO
#endif

@Suite struct FrameRingTests {
    /// A ring as simfb lays it out: `slots` slots, the frame in `latest`, rows padded to `stride`.
    private func ring(width: Int, height: Int, stride: Int, slots: Int = 2, latest: Int = 1, sequence: UInt64 = 7,
                      published: UInt64 = 0, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> Data {
        let slotBytes = stride * height
        var data = Data(count: FrameRing.headerSize + slots * slotBytes)
        func put<Value: FixedWidthInteger>(_ value: Value, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + $0.count, with: $0) }
        }
        data.replaceSubrange(0..<4, with: Data("SFBR".utf8))
        put(UInt32(2), at: 4)
        put(UInt32(slots), at: 8)
        put(UInt32(slotBytes), at: 12)
        put(UInt32(width), at: 16)
        put(UInt32(height), at: 20)
        put(UInt32(stride), at: 24)
        put(sequence, at: 32)
        put(UInt32(latest), at: 40)
        let slotHeader = 64 + 32 * latest
        put(sequence, at: slotHeader)
        put(published, at: slotHeader + 8)
        put(UInt32(width), at: slotHeader + 16)
        put(UInt32(height), at: slotHeader + 20)
        put(UInt32(stride), at: slotHeader + 24)
        let base = FrameRing.headerSize + latest * slotBytes
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let at = base + y * stride + x * 4
                data[at] = b; data[at + 1] = g; data[at + 2] = r; data[at + 3] = 255
            }
        }
        return data
    }

    @Test func readsTheLatestSlotPastRowPadding() throws {
        let data = ring(width: 3, height: 2, stride: 16) { x, y in (UInt8(x * 10), UInt8(y * 10), 99) }
        let frame = try FrameRing.latest(in: data)
        #expect(frame.width == 3 && frame.height == 2 && frame.stride == 16 && frame.sequence == 7)
        #expect(frame.rgbRows() == [0, 0, 99, 10, 0, 99, 20, 0, 99, 0, 10, 99, 10, 10, 99, 20, 10, 99])
        let screen = frame.screenFrame()
        #expect(screen.width == 3 && screen.height == 2)
        #expect(screen.pixels[0] != screen.pixels[1])
    }

    @Test func readsWhenTheNewestFrameWasPublished() throws {
        let data = ring(width: 2, height: 2, stride: 8, published: 1_795_000_000_250_000_000) { _, _ in (0, 0, 0) }
        let published = try FrameRing.lastPublished(in: data)
        #expect(abs(published.timeIntervalSince1970 - 1_795_000_000.25) < 0.001)
    }

    @Test func hasNoPublishTimeBeforeTheFirstFrame() {
        let data = ring(width: 2, height: 2, stride: 8, sequence: 0) { _, _ in (0, 0, 0) }
        #expect(throws: X86SimError.self) { try FrameRing.lastPublished(in: data) }
    }

    @Test func refusesSomethingElse() {
        var data = ring(width: 2, height: 2, stride: 8) { _, _ in (0, 0, 0) }
        data.replaceSubrange(0..<4, with: Data("NOPE".utf8))
        #expect(throws: X86SimError.self) { try FrameRing.latest(in: data) }
    }

    @Test func refusesARingWithNothingPublished() {
        let data = ring(width: 2, height: 2, stride: 8, sequence: 0) { _, _ in (0, 0, 0) }
        #expect(throws: X86SimError.self) { try FrameRing.latest(in: data) }
    }

    @Test func aPNGHoldsTheFramesPixels() throws {
        let frame = try FrameRing.latest(in: ring(width: 5, height: 4, stride: 24) { x, y in
            (UInt8(x * 50), UInt8(y * 60), UInt8((x + y) * 20))
        })
        let png = try PNGEncoder.encode(rgb: frame.rgbRows(), width: frame.width, height: frame.height)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #if canImport(ImageIO)
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 5 && image.height == 4)
        let decoded = try ScreenFrame(png: png)
        // ScreenFrame packs RGBA, little endian: red is the low byte.
        let pixel = decoded.pixels[3 * 5 + 2]
        #expect(pixel & 0xFF == 100 && (pixel >> 8) & 0xFF == 180 && (pixel >> 16) & 0xFF == 100)
        #endif
    }
}
