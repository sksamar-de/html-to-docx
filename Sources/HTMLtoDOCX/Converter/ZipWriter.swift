import Foundation
import Compression

/// A tiny, self-contained ZIP writer.
/// Implements the subset of the ZIP spec that Word and macOS's Archive Utility
/// require: per-entry local headers + DEFLATE compression (via Apple's
/// `Compression.framework`) + a central directory + EOCD.
///
/// We don't support ZIP64, encryption, or multi-disk archives — none of which
/// a `.docx` ever needs.
enum ZipWriter {

    struct Entry {
        let name: String
        let data: Data
    }

    /// Builds a complete ZIP archive in memory. For documents this small,
    /// writing in memory is faster than streaming to disk.
    static func archive(entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()
        var entryCount: UInt16 = 0

        let (dosTime, dosDate) = currentDOSDateTime()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = CRC32.compute(entry.data)
            let uncompressedSize = UInt32(entry.data.count)

            // Try DEFLATE; fall back to stored if compression actually grows
            // the payload (common for already-tiny XML files).
            let compressed = deflate(entry.data) ?? entry.data
            let useDeflate = compressed.count < entry.data.count
            let payload = useDeflate ? compressed : entry.data
            let method: UInt16 = useDeflate ? 8 : 0
            let compressedSize = UInt32(payload.count)

            let localHeaderOffset = UInt32(output.count)

            // Local file header.
            var local = Data()
            local.appendLE32(0x04034b50)         // signature
            local.appendLE16(20)                 // version needed
            local.appendLE16(0)                  // gp bit flag
            local.appendLE16(method)             // compression method
            local.appendLE16(dosTime)            // mod time
            local.appendLE16(dosDate)            // mod date
            local.appendLE32(crc)                // CRC-32
            local.appendLE32(compressedSize)
            local.appendLE32(uncompressedSize)
            local.appendLE16(UInt16(nameBytes.count))
            local.appendLE16(0)                  // extra field length
            local.append(nameBytes)
            output.append(local)
            output.append(payload)

            // Central directory entry.
            var central = Data()
            central.appendLE32(0x02014b50)       // signature
            central.appendLE16(20)               // version made by
            central.appendLE16(20)               // version needed
            central.appendLE16(0)                // gp bit flag
            central.appendLE16(method)
            central.appendLE16(dosTime)
            central.appendLE16(dosDate)
            central.appendLE32(crc)
            central.appendLE32(compressedSize)
            central.appendLE32(uncompressedSize)
            central.appendLE16(UInt16(nameBytes.count))
            central.appendLE16(0)                // extra
            central.appendLE16(0)                // comment
            central.appendLE16(0)                // disk number
            central.appendLE16(0)                // internal attrs
            central.appendLE32(0)                // external attrs
            central.appendLE32(localHeaderOffset)
            central.append(nameBytes)
            directory.append(central)

            entryCount += 1
        }

        let directoryOffset = UInt32(output.count)
        let directorySize = UInt32(directory.count)
        output.append(directory)

        // End of central directory record.
        var eocd = Data()
        eocd.appendLE32(0x06054b50)
        eocd.appendLE16(0)                       // disk number
        eocd.appendLE16(0)                       // disk with CD start
        eocd.appendLE16(entryCount)
        eocd.appendLE16(entryCount)
        eocd.appendLE32(directorySize)
        eocd.appendLE32(directoryOffset)
        eocd.appendLE16(0)                       // .ZIP comment length
        output.append(eocd)

        return output
    }

    // MARK: - DEFLATE

    private static func deflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let bufferSize = max(64, data.count + 64)
        var output = Data(count: bufferSize)

        let written: Int = data.withUnsafeBytes { srcRaw -> Int in
            let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            return output.withUnsafeMutableBytes { dstRaw -> Int in
                let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                return compression_encode_buffer(dst, bufferSize, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { return nil }
        output.count = written
        return output
    }

    // MARK: - DOS time/date

    private static func currentDOSDateTime() -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date()
        )
        let year = max(1980, components.year ?? 1980)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        let date = UInt16(((year - 1980) & 0x7F) << 9 | (month & 0x0F) << 5 | (day & 0x1F))
        let time = UInt16((hour & 0x1F) << 11 | (minute & 0x3F) << 5 | (second & 0x1F))
        return (time, date)
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
    mutating func appendLE32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}

/// Standard CRC-32 (poly 0xEDB88320). Lazily-built lookup table.
enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            for byte in buf {
                let idx = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = table[idx] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
