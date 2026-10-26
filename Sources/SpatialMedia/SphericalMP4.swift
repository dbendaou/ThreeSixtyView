import Foundation

public enum SpatialError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalid(String)

    public var description: String {
        switch self {
        case .truncated: return "MP4 ended before the box did"
        case .invalid(let reason): return reason
        }
    }
}

public enum SphericalMetadata {
    /// Spatial Media v1 UUID (Google spherical video).
    public static let uuid: [UInt8] = [
        0xFF, 0xCC, 0x82, 0x63, 0xF8, 0x55, 0x4A, 0x93,
        0x88, 0x14, 0x58, 0x7A, 0x02, 0x52, 0x1F, 0xDD,
    ]

    public static func xml(software: String = "ThreeSixtyView") -> String {
        "<?xml version=\"1.0\"?><rdf:SphericalVideo\nxmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"\nxmlns:GSpherical=\"http://ns.google.com/videos/1.0/spherical/\"><GSpherical:Spherical>true</GSpherical:Spherical><GSpherical:Stitched>true</GSpherical:Stitched><GSpherical:StitchingSoftware>\(software)</GSpherical:StitchingSoftware><GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType></rdf:SphericalVideo>"
    }

    public static func inject(data: Data, software: String = "ThreeSixtyView") throws -> Data {
        let writer = MemoryWriter()
        _ = try rewrite(reader: DataReader(data: data), software: software, into: writer)
        return writer.data
    }

    public static func injectFile(at url: URL, software: String = "ThreeSixtyView") throws {
        let temporary = url.appendingPathExtension("spherical-tmp")
        if FileManager.default.fileExists(atPath: temporary.path) {
            try FileManager.default.removeItem(at: temporary)
        }
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data()) else {
            throw SpatialError.invalid("Could not create \(temporary.path)")
        }
        let input = try FileHandle(forReadingFrom: url)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            _ = try rewrite(reader: try FileReader(handle: input), software: software, into: FileByteWriter(handle: output))
            try output.synchronize()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        try input.close()
        try output.close()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    public static func sphericalXML(in data: Data) -> String? {
        guard let moovBytes = try? moovPayload(in: DataReader(data: data)),
              let moov = try? parseBox(moovBytes, start: 0, end: moovBytes.count),
              case .children(let children) = moov.payload,
              let uuid = children.first(where: isSphericalUUID),
              case .leaf(let payload) = uuid.payload,
              payload.count > 16
        else { return nil }
        return String(data: payload.dropFirst(16), encoding: .utf8)
    }

    public static func containsEquirectangularSV3D(_ data: Data) -> Bool {
        guard let moov = try? moovPayload(in: DataReader(data: data)) else { return false }
        return moov.range(of: Data("equi".utf8)) != nil && moov.range(of: Data("sv3d".utf8)) != nil
    }

}

private protocol ByteReader {
    var count: Int64 { get }
    func read(offset: Int64, length: Int) throws -> Data
}

private protocol ByteWriter {
    func write(_ data: Data) throws
}

private struct DataReader: ByteReader {
    let data: Data
    var count: Int64 { Int64(data.count) }
    func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + Int64(length) <= count else { throw SpatialError.truncated }
        let start = Int(offset)
        return data.subdata(in: start..<(start + length))
    }
}

private final class MemoryWriter: ByteWriter {
    var data = Data()
    func write(_ data: Data) throws { self.data.append(data) }
}

private final class FileByteWriter: ByteWriter {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
}

private struct FileReader: ByteReader {
    let handle: FileHandle
    let count: Int64
    init(handle: FileHandle) throws {
        self.handle = handle
        count = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
    }
    func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + Int64(length) <= count else { throw SpatialError.truncated }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw SpatialError.truncated
        }
        return data
    }
}

extension SphericalMetadata {
    fileprivate static func rewrite(reader: ByteReader, software: String, into writer: ByteWriter) throws -> Int64 {
        let top = try scanTopLevel(reader)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw SpatialError.invalid("No moov box")
        }
        let moovBytes = try reader.read(offset: moov.offset, length: Int(moov.size))
        var tree = try parseBox(moovBytes, start: 0, end: moovBytes.count)
        try mutate(&tree, software: software)
        let unpatched = serialize(tree)
        let delta = Int64(unpatched.count) - moov.size
        try patchChunkOffsets(tree, top: top, moovDelta: delta, moovOffset: moov.offset)
        let serialized = serialize(tree)
        var written: Int64 = 0
        for box in top {
            if box.offset == moov.offset {
                try writer.write(serialized)
                written += Int64(serialized.count)
            } else {
                try streamCopy(reader: reader, offset: box.offset, length: box.size, into: writer)
                written += box.size
            }
        }
        return written
    }

    fileprivate static func moovPayload(in reader: ByteReader) throws -> Data {
        let top = try scanTopLevel(reader)
        guard let moov = top.first(where: { $0.type == "moov" }) else {
            throw SpatialError.invalid("No moov box")
        }
        return try reader.read(offset: moov.offset, length: Int(moov.size))
    }
}

private struct TopBox {
    var type: String
    var offset: Int64
    var size: Int64
}

private func scanTopLevel(_ reader: ByteReader) throws -> [TopBox] {
    var offset: Int64 = 0
    var boxes: [TopBox] = []
    while offset + 8 <= reader.count {
        let header = try readHeader(reader, offset: offset, limit: reader.count)
        boxes.append(TopBox(type: header.type, offset: offset, size: header.totalSize))
        offset += header.totalSize
    }
    guard offset == reader.count else { throw SpatialError.invalid("Top-level boxes do not fill the file") }
    return boxes
}

private struct Header {
    var type: String
    var headerLength: Int
    var totalSize: Int64
}

private func readHeader(_ reader: ByteReader, offset: Int64, limit: Int64) throws -> Header {
    let raw = try reader.read(offset: offset, length: 8)
    var size = Int64(raw.u32(0))
    let type = raw.fourCC(4)
    var headerLength = 8
    if size == 1 {
        let extra = try reader.read(offset: offset + 8, length: 8)
        size = Int64(bitPattern: extra.u64(0))
        headerLength = 16
    } else if size == 0 {
        size = limit - offset
    }
    guard size >= Int64(headerLength), offset + size <= limit else { throw SpatialError.truncated }
    return Header(type: type, headerLength: headerLength, totalSize: size)
}

private final class BoxNode {
    var type: String
    var payload: Payload
    init(type: String, payload: Payload) {
        self.type = type
        self.payload = payload
    }
    enum Payload {
        case leaf(Data)
        case children([BoxNode])
        case prefixed(Data, [BoxNode])
    }
}

private let containerTypes: Set<String> = [
    "moov", "trak", "mdia", "minf", "stbl", "dinf", "udta", "edts", "mvex", "moof", "traf",
]
private let visualTypes: Set<String> = [
    "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "encv", "vp09", "av01", "mp4v",
]

private func parseBox(_ data: Data, start: Int, end: Int) throws -> BoxNode {
    guard end - start >= 8 else { throw SpatialError.truncated }
    var size = Int(data.u32(start))
    let type = data.fourCC(start + 4)
    var header = 8
    if size == 1 {
        guard end - start >= 16 else { throw SpatialError.truncated }
        size = Int(data.u64(start + 8))
        header = 16
    } else if size == 0 {
        size = end - start
    }
    guard size >= header, start + size <= end else { throw SpatialError.truncated }
    let payloadStart = start + header
    let payloadEnd = start + size
    let payload = data.subdata(in: payloadStart..<payloadEnd)
    if containerTypes.contains(type) {
        return BoxNode(type: type, payload: .children(try parseChildren(payload, start: 0, end: payload.count)))
    }
    if type == "stsd" || type == "meta" {
        let prefixLength = type == "stsd" ? 8 : 4
        guard payload.count >= prefixLength else { throw SpatialError.truncated }
        let prefix = payload.subdata(in: 0..<prefixLength)
        let children = try parseChildren(payload, start: prefixLength, end: payload.count)
        return BoxNode(type: type, payload: .prefixed(prefix, children))
    }
    if visualTypes.contains(type), payload.count >= 78 {
        let fixed = payload.subdata(in: 0..<78)
        let children = try parseChildren(payload, start: 78, end: payload.count)
        return BoxNode(type: type, payload: .prefixed(fixed, children))
    }
    return BoxNode(type: type, payload: .leaf(payload))
}

private func parseChildren(_ data: Data, start: Int, end: Int) throws -> [BoxNode] {
    var cursor = start
    var children: [BoxNode] = []
    while cursor + 8 <= end {
        let size32 = Int(data.u32(cursor))
        let size: Int
        if size32 == 1 {
            guard cursor + 16 <= end else { throw SpatialError.truncated }
            size = Int(data.u64(cursor + 8))
        } else if size32 == 0 {
            size = end - cursor
        } else {
            size = size32
        }
        guard size >= 8, cursor + size <= end else { throw SpatialError.truncated }
        children.append(try parseBox(data, start: cursor, end: cursor + size))
        cursor += size
    }
    guard cursor == end else { throw SpatialError.invalid("Boxes left a gap or overlapped") }
    return children
}

private func serialize(_ node: BoxNode) -> Data {
    let body: Data
    switch node.payload {
    case .leaf(let data):
        body = data
    case .children(let children):
        body = children.reduce(into: Data()) { $0.append(serialize($1)) }
    case .prefixed(let prefix, let children):
        var data = prefix
        for child in children { data.append(serialize(child)) }
        body = data
    }
    var out = Data()
    let total = 8 + body.count
    if total > Int(UInt32.max) {
        out.appendU32(1)
        out.append(contentsOf: node.type.utf8)
        out.appendU64(UInt64(16 + body.count))
        // header was counted as 8 above; extended header is 16. Rebuild.
        out = Data()
        out.appendU32(1)
        out.append(contentsOf: node.type.utf8)
        out.appendU64(UInt64(16 + body.count))
    } else {
        out.appendU32(UInt32(total))
        out.append(contentsOf: node.type.utf8)
    }
    out.append(body)
    return out
}

private func mutate(_ moov: inout BoxNode, software: String) throws {
    guard case .children(var children) = moov.payload else {
        throw SpatialError.invalid("moov is not a container")
    }
    let xml = Data(SphericalMetadata.xml(software: software).utf8)
    var uuidPayload = Data(SphericalMetadata.uuid)
    uuidPayload.append(xml)
    if let index = children.firstIndex(where: isSphericalUUID) {
        children[index] = BoxNode(type: "uuid", payload: .leaf(uuidPayload))
    } else {
        children.append(BoxNode(type: "uuid", payload: .leaf(uuidPayload)))
    }
    for child in children where child.type == "trak" {
        insertSV3D(child)
    }
    moov.payload = .children(children)
}

private func isSphericalUUID(_ node: BoxNode) -> Bool {
    guard node.type == "uuid", case .leaf(let data) = node.payload, data.count >= 16 else { return false }
    return Array(data.prefix(16)) == SphericalMetadata.uuid
}

private func insertSV3D(_ node: BoxNode) {
    switch node.payload {
    case .children(let children):
        for child in children { insertSV3D(child) }
    case .prefixed(let prefix, var children):
        if visualTypes.contains(node.type) {
            if !children.contains(where: { $0.type == "sv3d" }) {
                children.append(BoxNode(type: "sv3d", payload: .leaf(sv3dPayload())))
            }
            node.payload = .prefixed(prefix, children)
        } else {
            for child in children { insertSV3D(child) }
            node.payload = .prefixed(prefix, children)
        }
    case .leaf:
        break
    }
}

private func sv3dPayload() -> Data {
    let svhd = box("svhd", Data([0, 0, 0, 0]) + Data("ThreeSixtyView".utf8))
    var pose = Data([0, 0, 0, 0])
    pose.appendU32(0)
    pose.appendU32(0)
    pose.appendU32(0)
    let prhd = box("prhd", pose)
    var bounds = Data([0, 0, 0, 0])
    bounds.appendU32(0)
    bounds.appendU32(0)
    bounds.appendU32(0)
    bounds.appendU32(0)
    let equi = box("equi", bounds)
    let proj = box("proj", prhd + equi)
    return svhd + proj
}

private func patchChunkOffsets(_ node: BoxNode, top: [TopBox], moovDelta: Int64, moovOffset: Int64) throws {
    switch node.payload {
    case .children(let children):
        for child in children { try patchChunkOffsets(child, top: top, moovDelta: moovDelta, moovOffset: moovOffset) }
    case .prefixed(_, let children):
        for child in children { try patchChunkOffsets(child, top: top, moovDelta: moovDelta, moovOffset: moovOffset) }
    case .leaf(var data):
        if node.type == "stco" {
            data = try rewriteOffsets(data, wide: false, top: top, moovDelta: moovDelta, moovOffset: moovOffset)
            node.payload = .leaf(data)
        } else if node.type == "co64" {
            data = try rewriteOffsets(data, wide: true, top: top, moovDelta: moovDelta, moovOffset: moovOffset)
            node.payload = .leaf(data)
        }
    }
}

private func rewriteOffsets(_ data: Data, wide: Bool, top: [TopBox], moovDelta: Int64, moovOffset: Int64) throws -> Data {
    guard data.count >= 8 else { throw SpatialError.invalid("Short chunk offset box") }
    let count = Int(data.u32(4))
    let width = wide ? 8 : 4
    guard data.count >= 8 + count * width else { throw SpatialError.truncated }
    var copy = data
    for index in 0..<count {
        let at = 8 + index * width
        let original: UInt64 = wide ? data.u64(at) : UInt64(data.u32(at))
        let moved = relocated(Int64(original), top: top, moovDelta: moovDelta, moovOffset: moovOffset)
        if wide {
            copy.writeU64(UInt64(moved), at: at)
        } else if moved > Int64(UInt32.max) || moved < 0 {
            throw SpatialError.invalid("Chunk offset no longer fits stco")
        } else {
            copy.writeU32(UInt32(moved), at: at)
        }
    }
    return copy
}

private func relocated(_ offset: Int64, top: [TopBox], moovDelta: Int64, moovOffset: Int64) -> Int64 {
    var shift: Int64 = 0
    for box in top where box.offset < offset && box.offset == moovOffset {
        shift += moovDelta
    }
    return offset + shift
}

private func streamCopy(reader: ByteReader, offset: Int64, length: Int64, into writer: ByteWriter) throws {
    var remaining = length
    var cursor = offset
    while remaining > 0 {
        let chunk = Int(min(remaining, 1024 * 1024))
        let data = try reader.read(offset: cursor, length: chunk)
        try writer.write(data)
        cursor += Int64(chunk)
        remaining -= Int64(chunk)
    }
}

private func box(_ type: String, _ payload: Data) -> Data {
    var data = Data()
    data.appendU32(UInt32(8 + payload.count))
    data.append(contentsOf: type.utf8)
    data.append(payload)
    return data
}

private extension Data {
    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16) | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
    func u64(_ offset: Int) -> UInt64 {
        (UInt64(u32(offset)) << 32) | UInt64(u32(offset + 4))
    }
    func fourCC(_ offset: Int) -> String {
        let i = startIndex + offset
        return String(bytes: [self[i], self[i + 1], self[i + 2], self[i + 3]], encoding: .isoLatin1) ?? "????"
    }
    mutating func appendU32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
    mutating func appendU64(_ value: UInt64) {
        appendU32(UInt32(value >> 32))
        appendU32(UInt32(value & 0xFFFF_FFFF))
    }
    mutating func writeU32(_ value: UInt32, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8((value >> 24) & 0xFF)
        self[i + 1] = UInt8((value >> 16) & 0xFF)
        self[i + 2] = UInt8((value >> 8) & 0xFF)
        self[i + 3] = UInt8(value & 0xFF)
    }
    mutating func writeU64(_ value: UInt64, at offset: Int) {
        writeU32(UInt32(value >> 32), at: offset)
        writeU32(UInt32(value & 0xFFFF_FFFF), at: offset + 4)
    }
}
