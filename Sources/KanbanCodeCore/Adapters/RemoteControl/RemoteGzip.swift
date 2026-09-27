#if canImport(Compression)
import Compression
#else
import CZlib
#endif
import Foundation

/// gzip (RFC 1952) around a raw DEFLATE stream: the Compression framework on
/// Apple platforms, zlib elsewhere.
enum RemoteGzip {
    /// HTTP bodies smaller than this go out as they are.
    static let minimumBytes = 8 * 1024

    static func accepts(_ request: RemoteHTTPRequest) -> Bool {
        guard let header = request.header("accept-encoding")?.lowercased() else { return false }
        return header.split(separator: ",").contains { part in
            let fields = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.first == "gzip" else { return false }
            return !fields.dropFirst().contains { $0 == "q=0" || $0 == "q=0.0" }
        }
    }

    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 10 + 1024
        var deflated = Data(count: capacity)
        let written = deflated.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                rawDeflate(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count
                )
            }
        }
        guard written > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated.prefix(written))
        appendLittleEndian(crc32(data), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: data.count), to: &out)
        return out
    }

    /// Raw DEFLATE of `count` bytes into `dst`; the bytes written, 0 on failure.
    private static func rawDeflate(_ dst: UnsafeMutablePointer<UInt8>, _ capacity: Int, _ src: UnsafePointer<UInt8>, _ count: Int) -> Int {
        #if canImport(Compression)
        return compression_encode_buffer(dst, capacity, src, count, nil, COMPRESSION_ZLIB)
        #else
        var stream = z_stream()
        // Negative window bits: raw DEFLATE, no zlib header.
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
        defer { deflateEnd(&stream) }
        stream.next_in = UnsafeMutablePointer(mutating: src)
        stream.avail_in = uInt(count)
        stream.next_out = dst
        stream.avail_out = uInt(capacity)
        guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { return 0 }
        return Int(stream.total_out)
        #endif
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
