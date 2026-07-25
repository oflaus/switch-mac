import Foundation

/// Leitor little-endian para datasets PTP/MTP.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else {
            throw MTPError.protocolError("dataset truncado (faltam \(n - remaining) bytes)")
        }
        defer { offset += n }
        return bytes[offset ..< offset + n]
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u16() throws -> UInt16 {
        let s = try take(2)
        let b = Array(s)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = Array(try take(4))
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | hi << 32
    }

    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    /// String PTP: 1 byte com a quantidade de UTF-16 (incluindo o NUL final), seguido dos code units.
    mutating func string() throws -> String {
        let count = Int(try u8())
        if count == 0 { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0 ..< count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func array<T>(_ element: (inout ByteReader) throws -> T) throws -> [T] {
        let count = Int(try u32())
        // Sanidade: evita alocação absurda se o dataset vier corrompido.
        guard count <= 1_000_000 else {
            throw MTPError.protocolError("array com tamanho implausível (\(count))")
        }
        var out: [T] = []
        out.reserveCapacity(count)
        for _ in 0 ..< count { out.append(try element(&self)) }
        return out
    }

    mutating func u16Array() throws -> [UInt16] { try array { try $0.u16() } }
    mutating func u32Array() throws -> [UInt32] { try array { try $0.u32() } }
}

/// Escritor little-endian para datasets PTP/MTP.
struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8)   { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32)) }

    mutating func string(_ s: String) {
        if s.isEmpty { u8(0); return }
        var units = Array(s.utf16)
        if units.count > 254 { units = Array(units.prefix(254)) }
        units.append(0)
        u8(UInt8(units.count))
        for u in units { u16(u) }
    }

    var data: Data { Data(bytes) }
}
