import Foundation
import zlib

/// Reader for Apple Biome "SEGB" segment files.
///
/// Version 2 layout (macOS 14+/iOS 17+, observed on macOS 15):
///   * 32-byte header: "SEGB", UInt32 entry count, Double creation time, 16 bytes reserved.
///   * Records from offset 32, each 4-byte aligned: UInt32 CRC32 of payload, UInt32 flag, payload.
///   * An entry table growing backwards from the end of the file, 16 bytes per entry:
///     UInt32 end offset (relative to byte 32), UInt32 state, Double timestamp.
///     States: 1 = live, 3 = deleted (payload zeroed), 4 = segment closed (offset 0).
///
/// Version 1 (older systems) keeps "SEGB" at offset 52 and has a different layout; it is detected
/// and reported, not parsed.
enum SEGB {
    enum Format: String { case v1, v2, unknown }

    struct Stats {
        var entries = 0, live = 0, deleted = 0, badCRC = 0
    }

    static func format(of data: Data) -> Format {
        if data.count >= 32, data.prefix(4) == Data("SEGB".utf8) { return .v2 }
        if data.count >= 56, data[52..<56] == Data("SEGB".utf8) { return .v1 }
        return .unknown
    }

    /// Returns the payloads of live, CRC-valid records.
    static func records(_ url: URL, stats: inout Stats) throws -> [Data] {
        let data = try Data(contentsOf: url)
        switch format(of: data) {
        case .v2: break
        case .v1: throw ArchiverError("\(url.lastPathComponent): SEGB v1 segment (older macOS) is not supported yet")
        case .unknown: throw ArchiverError("\(url.lastPathComponent): not a SEGB file")
        }
        func u32(_ off: Int) -> UInt32 {
            UInt32(littleEndian: data[off..<off + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        let count = Int(u32(4))
        guard count * 16 + 32 <= data.count else { throw ArchiverError("\(url.lastPathComponent): bad entry count") }

        var records: [Data] = []
        var start = 32
        for k in 0..<count {
            let entryOff = data.count - 16 * (k + 1)
            let end = Int(u32(entryOff))
            let state = u32(entryOff + 4)
            if end == 0 { continue }
            let recEnd = 32 + end
            guard recEnd <= entryOff, start + 8 <= recEnd else { break }
            stats.entries += 1
            if state == 1 {
                let crc = u32(start)
                let payload = data[(start + 8)..<recEnd]
                let actual = payload.withUnsafeBytes { buf in
                    UInt32(crc32(0, buf.bindMemory(to: Bytef.self).baseAddress, uInt(buf.count)))
                }
                if crc == actual {
                    records.append(Data(payload))
                    stats.live += 1
                } else {
                    stats.badCRC += 1
                }
            } else if state == 3 {
                stats.deleted += 1
            }
            start = (recEnd + 3) & ~3
        }
        return records
    }
}

/// Just enough protobuf decoding for Biome event payloads.
enum Protobuf {
    enum Value { case varint(UInt64), fixed64(Double), bytes(Data), fixed32 }

    static func decode(_ data: Data) -> [Int: [Value]]? {
        var out: [Int: [Value]] = [:]
        var i = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                result |= UInt64(b & 0x7f) << shift
                if b < 0x80 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < data.endIndex {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                value = .varint(v)
            case 1:
                guard i + 8 <= data.endIndex else { return nil }
                let bits = data[i..<i + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                value = .fixed64(Double(bitPattern: UInt64(littleEndian: bits)))
                i += 8
            case 2:
                guard let len = varint(), i + Int(len) <= data.endIndex else { return nil }
                value = .bytes(data[i..<i + Int(len)])
                i += Int(len)
            case 5:
                guard i + 4 <= data.endIndex else { return nil }
                value = .fixed32
                i += 4
            default:
                return nil
            }
            out[field, default: []].append(value)
        }
        return out
    }
}
