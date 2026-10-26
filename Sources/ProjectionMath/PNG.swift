import Foundation

public enum PNGError: Error, Equatable, CustomStringConvertible {
    case truncated
    case badSignature
    case badChecksum
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated: return "PNG data ended early"
        case .badSignature: return "Not a PNG"
        case .badChecksum: return "PNG checksum mismatch"
        case .unsupported(let reason): return "Unsupported PNG (\(reason))"
        }
    }
}

public enum PNG {
    public static func encode(_ image: RGBAImage) -> Data {
        var raw = Data()
        raw.reserveCapacity(image.height * (1 + image.width * 4))
        for y in 0..<image.height {
            raw.append(0)
            let start = y * image.width * 4
            raw.append(contentsOf: image.rgba[start..<(start + image.width * 4)])
        }
        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(image.width))
        ihdr.appendBigEndian(UInt32(image.height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(chunk("IHDR", ihdr))
        data.append(chunk("IDAT", zlibStore(raw)))
        data.append(chunk("IEND", Data()))
        return data
    }

    public static func decode(_ data: Data) throws -> RGBAImage {
        guard data.count >= 8 else { throw PNGError.truncated }
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard Array(data.prefix(8)) == signature else { throw PNGError.badSignature }
        var offset = 8
        var width = 0
        var height = 0
        var idat = Data()
        var sawEnd = false
        while offset + 8 <= data.count {
            let length = Int(data.bigEndianUInt32(offset))
            let type = String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .utf8) ?? ""
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd + 4 <= data.count else { throw PNGError.truncated }
            let payload = data.subdata(in: payloadStart..<payloadEnd)
            let expected = crc32(data.subdata(in: (offset + 4)..<payloadEnd))
            let actual = data.bigEndianUInt32(payloadEnd)
            guard expected == actual else { throw PNGError.badChecksum }
            if type == "IHDR" {
                guard payload.count >= 13 else { throw PNGError.truncated }
                width = Int(payload.bigEndianUInt32(0))
                height = Int(payload.bigEndianUInt32(4))
                guard payload[8] == 8, payload[9] == 6, payload[10] == 0, payload[11] == 0, payload[12] == 0 else {
                    throw PNGError.unsupported("only 8-bit non-interlaced RGBA")
                }
            } else if type == "IDAT" {
                idat.append(payload)
            } else if type == "IEND" {
                sawEnd = true
                break
            }
            offset = payloadEnd + 4
        }
        guard sawEnd, width > 0, height > 0 else { throw PNGError.truncated }
        let inflated = try inflateStored(idat)
        let stride = 1 + width * 4
        guard inflated.count == height * stride else {
            throw PNGError.unsupported("scanline size")
        }
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            let row = y * stride
            guard inflated[row] == 0 else { throw PNGError.unsupported("filter \(inflated[row])") }
            rgba.append(contentsOf: inflated[(row + 1)..<(row + stride)])
        }
        return RGBAImage(width: width, height: height, rgba: rgba)
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(payload.count))
        let typeData = Data(type.utf8)
        data.append(typeData)
        data.append(payload)
        data.appendBigEndian(crc32(typeData + payload))
        return data
    }

    private static func zlibStore(_ raw: Data) -> Data {
        var z = Data([0x78, 0x01])
        z.append(deflateStored(raw))
        z.appendBigEndian(adler32(raw))
        return z
    }

    private static func deflateStored(_ raw: Data) -> Data {
        var out = Data()
        if raw.isEmpty {
            out.append(1)
            out.append(contentsOf: [0, 0, 0xFF, 0xFF])
            return out
        }
        var offset = 0
        while offset < raw.count {
            let chunk = min(65535, raw.count - offset)
            let last: UInt8 = offset + chunk == raw.count ? 1 : 0
            out.append(last)
            let len = UInt16(chunk)
            out.append(UInt8(len & 0xFF))
            out.append(UInt8(len >> 8))
            let nlen = ~len
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8(nlen >> 8))
            out.append(raw.subdata(in: offset..<(offset + chunk)))
            offset += chunk
        }
        return out
    }

    private static func inflateStored(_ zlib: Data) throws -> Data {
        guard zlib.count >= 6 else { throw PNGError.truncated }
        guard zlib[0] == 0x78 else { throw PNGError.unsupported("zlib header") }
        var offset = 2
        var raw = Data()
        while offset < zlib.count - 4 {
            let header = zlib[offset]
            offset += 1
            let last = header & 1 == 1
            let kind = (header >> 1) & 3
            guard kind == 0 else { throw PNGError.unsupported("deflate block \(kind)") }
            guard offset + 4 <= zlib.count - 4 else { throw PNGError.truncated }
            let len = Int(zlib[offset]) | (Int(zlib[offset + 1]) << 8)
            let nlen = Int(zlib[offset + 2]) | (Int(zlib[offset + 3]) << 8)
            guard (len ^ 0xFFFF) == nlen else { throw PNGError.badChecksum }
            offset += 4
            guard offset + len <= zlib.count - 4 else { throw PNGError.truncated }
            raw.append(zlib.subdata(in: offset..<(offset + len)))
            offset += len
            if last { break }
        }
        let checksum = adler32(raw)
        let stored = zlib.bigEndianUInt32(zlib.count - 4)
        guard checksum == stored else { throw PNGError.badChecksum }
        return raw
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xFFFF_FFFF : 0
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func bigEndianUInt32(_ offset: Int) -> UInt32 {
        let start = startIndex + offset
        return (UInt32(self[start]) << 24)
            | (UInt32(self[start + 1]) << 16)
            | (UInt32(self[start + 2]) << 8)
            | UInt32(self[start + 3])
    }
}
