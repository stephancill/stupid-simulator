import CZlib
import Foundation

/// Writes 8 bit RGB images as PNG, for screenshots of x86Sim frames where there is no ImageIO.
public enum PNGEncoder {
    public static func encode(rgb: [UInt8], width: Int, height: Int) throws -> Data {
        precondition(rgb.count == width * height * 3, "three bytes a pixel")
        // Each row starts with its filter type; 0, none, keeps this simple and zlib does the rest.
        var filtered = [UInt8](repeating: 0, count: (width * 3 + 1) * height)
        rgb.withUnsafeBufferPointer { source in
            filtered.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = y * (width * 3 + 1)
                    out[row] = 0
                    memcpy(out.baseAddress! + row + 1, source.baseAddress! + y * width * 3, width * 3)
                }
            }
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 2, 0, 0, 0]) // 8 bits, RGB, deflate, no filter set, no interlace
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", try deflate(filtered))
        png.appendChunk("IEND", Data())
        return png
    }

    static func deflate(_ bytes: [UInt8]) throws -> Data {
        var length = compressBound(uLong(bytes.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        // Level 1: a screenshot is mostly flat colour, and a phone screen is large.
        let status = compress2(&out, &length, bytes, uLong(bytes.count), 1)
        guard status == Z_OK else {
            throw X86SimError.failed("Could not compress the screenshot: zlib status \(status).")
        }
        return Data(out.prefix(Int(length)))
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        let crc = typed.withUnsafeBytes { raw in
            crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count))
        }
        appendBigEndian(UInt32(crc))
    }
}
