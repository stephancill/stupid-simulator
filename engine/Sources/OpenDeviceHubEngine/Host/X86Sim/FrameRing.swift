import Foundation

/// One frame from x86Sim's framebuffer: BGRA rows, portrait native, `stride` bytes apart.
public struct X86SimFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let sequence: UInt64
    public let bytes: Data

    /// Packed 32 bit pixels for comparing frames. The byte order does not matter for that, only
    /// that it is the same in every frame.
    public func screenFrame() -> ScreenFrame {
        var pixels = [UInt32](repeating: 0, count: width * height)
        bytes.withUnsafeBytes { raw in
            for y in 0..<height {
                let row = raw.baseAddress! + y * stride
                _ = pixels.withUnsafeMutableBufferPointer { out in
                    memcpy(out.baseAddress! + y * width, row, width * 4)
                }
            }
        }
        return ScreenFrame(width: width, height: height, pixels: pixels)
    }

    /// RGB rows without padding, which is what the PNG holds.
    public func rgbRows() -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        bytes.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let from = y * stride + x * 4
                    let to = (y * width + x) * 3
                    rgb[to] = source[from + 2]
                    rgb[to + 1] = source[from + 1]
                    rgb[to + 2] = source[from]
                }
            }
        }
        return rgb
    }
}

/// Reads simfb's shared-memory frame ring (`/dev/shm/x86sim-a64[-<name>]-simfb.ring`). Layout from
/// x86Sim 0.3.0's `cli/libexec/fbring.py`, little endian:
///
///     header, 4096 bytes: magic "SFBR", version u32, slots u32, slot bytes u32, width u32,
///         height u32, stride u32, pad u32, seq u64 (frames published), latest u32 (its slot)
///     per slot at 64 + 32 * i: seq u64 (0 while written), time u64, width u32, height u32,
///         stride u32
///     slot i at 4096 + i * slot bytes: the frame's rows
///
/// simfb fills a slot other than the latest, then publishes it, so a reader copies the latest slot
/// and keeps the copy only if that slot's seq has not changed meanwhile.
public enum FrameRing {
    static let headerSize = 4096
    static let magic = Data("SFBR".utf8)

    public static func latest(at ring: URL) throws -> X86SimFrame {
        let data: Data
        do {
            // Mapped, not read: the ring holds several full frames, and only one is copied.
            data = try Data(contentsOf: ring, options: .alwaysMapped)
        } catch {
            throw X86SimError.failed("x86Sim's frame ring at \(ring.path) could not be read. Is the device running?")
        }
        return try latest(in: data)
    }

    static func latest(in ring: Data) throws -> X86SimFrame {
        guard ring.count >= headerSize, ring.prefix(4) == magic else {
            throw X86SimError.failed("x86Sim's frame ring has no SFBR header.")
        }
        let slots = Int(ring.littleEndian(UInt32.self, at: 8))
        let slotBytes = Int(ring.littleEndian(UInt32.self, at: 12))
        for _ in 0..<4 {
            let published = ring.littleEndian(UInt64.self, at: 32)
            let latest = Int(ring.littleEndian(UInt32.self, at: 40))
            guard published > 0, latest < slots else { break }
            let slotHeader = 64 + 32 * latest
            let sequence = ring.littleEndian(UInt64.self, at: slotHeader)
            let width = Int(ring.littleEndian(UInt32.self, at: slotHeader + 16))
            let height = Int(ring.littleEndian(UInt32.self, at: slotHeader + 20))
            let stride = Int(ring.littleEndian(UInt32.self, at: slotHeader + 24))
            let start = headerSize + latest * slotBytes
            guard sequence > 0, width > 0, height > 0, stride >= width * 4, stride * height <= slotBytes,
                  start + stride * height <= ring.count else { continue }
            let bytes = Data(ring[ring.startIndex + start..<ring.startIndex + start + stride * height])
            if ring.littleEndian(UInt64.self, at: slotHeader) == sequence {
                return X86SimFrame(width: width, height: height, stride: stride, sequence: sequence, bytes: bytes)
            }
        }
        throw X86SimError.failed("x86Sim's frame ring has not published a frame yet.")
    }

    /// When the newest frame was published, from its slot's time (CLOCK_REALTIME, nanoseconds),
    /// without copying any pixels. simfb publishes only when the screen changes: an idle home
    /// screen published no frame in 5 s (x86Sim 0.5.0, iOS 27.2), so an old newest frame means a
    /// still screen.
    public static func lastPublished(at ring: URL) throws -> Date {
        let data: Data
        do {
            data = try Data(contentsOf: ring, options: .alwaysMapped)
        } catch {
            throw X86SimError.failed("x86Sim's frame ring at \(ring.path) could not be read. Is the device running?")
        }
        return try lastPublished(in: data)
    }

    static func lastPublished(in ring: Data) throws -> Date {
        guard ring.count >= headerSize, ring.prefix(4) == magic else {
            throw X86SimError.failed("x86Sim's frame ring has no SFBR header.")
        }
        let slots = Int(ring.littleEndian(UInt32.self, at: 8))
        let latest = Int(ring.littleEndian(UInt32.self, at: 40))
        guard ring.littleEndian(UInt64.self, at: 32) > 0, latest < slots else {
            throw X86SimError.failed("x86Sim's frame ring has not published a frame yet.")
        }
        let nanoseconds = ring.littleEndian(UInt64.self, at: 64 + 32 * latest + 8)
        return Date(timeIntervalSince1970: Double(nanoseconds) / 1e9)
    }
}

extension Data {
    func littleEndian<Value: FixedWidthInteger>(_: Value.Type, at offset: Int) -> Value {
        var value: Value = 0
        Swift.withUnsafeMutableBytes(of: &value) { out in
            out.copyBytes(from: self[(startIndex + offset)..<(startIndex + offset + MemoryLayout<Value>.size)])
        }
        return Value(littleEndian: value)
    }
}
