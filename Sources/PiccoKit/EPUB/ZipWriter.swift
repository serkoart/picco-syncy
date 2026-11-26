import Compression
import Foundation

/// CRC-32 (IEEE 802.3), as used by ZIP.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A minimal ZIP writer: enough for EPUB (stored + deflated entries, no ZIP64).
struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max((c.year ?? 1980) - 1980, 0)
        dosDate = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
    }

    /// Adds a file. Content is deflated when `compress` is true and deflating actually saves space.
    mutating func add(_ path: String, _ content: Data, compress: Bool = true) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        var method: UInt16 = 0
        var payload = content
        if compress, let deflated = Self.deflate(content), deflated.count < content.count {
            method = 8
            payload = deflated
        }
        let offset = UInt32(output.count)
        let flags: UInt16 = path.utf8.allSatisfy { $0 < 0x80 } ? 0 : 0x0800

        output.le32(0x0403_4B50)
        output.le16(20)  // version needed
        output.le16(flags)
        output.le16(method)
        output.le16(dosTime)
        output.le16(dosDate)
        output.le32(crc)
        output.le32(UInt32(payload.count))
        output.le32(UInt32(content.count))
        output.le16(UInt16(name.count))
        output.le16(0)  // extra length
        output.append(name)
        output.append(payload)

        entries.append(Entry(
            name: name, crc: crc, compressedSize: UInt32(payload.count),
            size: UInt32(content.count), method: method, offset: offset))
    }

    /// Writes the central directory and returns the finished archive.
    mutating func finish() -> Data {
        let directoryOffset = UInt32(output.count)
        for e in entries {
            let flags: UInt16 = e.name.allSatisfy { $0 < 0x80 } ? 0 : 0x0800
            output.le32(0x0201_4B50)
            output.le16(20)  // version made by
            output.le16(20)  // version needed
            output.le16(flags)
            output.le16(e.method)
            output.le16(dosTime)
            output.le16(dosDate)
            output.le32(e.crc)
            output.le32(e.compressedSize)
            output.le32(e.size)
            output.le16(UInt16(e.name.count))
            output.le16(0)  // extra
            output.le16(0)  // comment
            output.le16(0)  // disk
            output.le16(0)  // internal attributes
            output.le32(0)  // external attributes
            output.le32(e.offset)
            output.append(e.name)
        }
        let directorySize = UInt32(output.count) - directoryOffset
        output.le32(0x0605_4B50)
        output.le16(0)
        output.le16(0)
        output.le16(UInt16(entries.count))
        output.le16(UInt16(entries.count))
        output.le32(directorySize)
        output.le32(directoryOffset)
        output.le16(0)
        return output
    }

    /// Raw DEFLATE (RFC 1951), which is what ZIP method 8 expects. Apple's COMPRESSION_ZLIB emits exactly that.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

extension Data {
    mutating func le16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func le32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
}
