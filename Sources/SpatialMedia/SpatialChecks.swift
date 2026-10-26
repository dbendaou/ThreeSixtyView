import Foundation

public struct SpatialCheckReport: Sendable {
    public var passed: [String]
    public var failures: [String]
    public var ok: Bool { failures.isEmpty }
}

public enum SpatialChecks {
    public static func run() -> SpatialCheckReport {
        let cases: [(String, () throws -> Void)] = [
            ("inject leaves mdat offsets", injectsWithoutMovingMdat),
            ("moov-first patches offsets", moovBeforeMdatPatchesChunkOffsets),
            ("file inject round trip", fileRoundTrip),
        ]
        var passed: [String] = []
        var failures: [String] = []
        for (name, body) in cases {
            do {
                try body()
                passed.append(name)
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        return SpatialCheckReport(passed: passed, failures: failures)
    }
}

private struct CheckError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError(message) }
}

private func injectsWithoutMovingMdat() throws {
    let movie = SyntheticMovie.make(moovFirst: false)
    let injected = try SphericalMetadata.inject(data: movie.bytes)
    let xml = SphericalMetadata.sphericalXML(in: injected) ?? ""
    try expect(xml.contains("<GSpherical:Spherical>true</GSpherical:Spherical>"), "spherical flag")
    try expect(xml.contains("<GSpherical:Stitched>true</GSpherical:Stitched>"), "stitched")
    try expect(xml.contains("<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>"), "projection")
    try expect(xml.contains("ThreeSixtyView"), "software")
    try expect(SphericalMetadata.containsEquirectangularSV3D(injected), "sv3d")
    try expect(Int64(chunkOffset(in: injected)) == movie.mdatPayloadOffset, "stco unchanged")
    try expect(try SphericalMetadata.inject(data: injected).count == injected.count, "idempotent")
    try expect(topLevelSum(injected) == injected.count, "box sizes")
}

private func moovBeforeMdatPatchesChunkOffsets() throws {
    let movie = SyntheticMovie.make(moovFirst: true)
    let injected = try SphericalMetadata.inject(data: movie.bytes)
    let moved = Int64(chunkOffset(in: injected))
    try expect(moved != movie.mdatPayloadOffset, "offset moved")
    try expect(moved == movie.mdatPayloadOffset + Int64(injected.count - movie.bytes.count), "delta")
    let payload = injected.subdata(in: Int(moved)..<Int(moved) + 4)
    try expect(Array(payload) == [0x11, 0x22, 0x33, 0x44], "mdat bytes")
    try expect(SphericalMetadata.sphericalXML(in: injected) != nil, "xml")
}

private func fileRoundTrip() throws {
    let movie = SyntheticMovie.make(moovFirst: false)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spherical-test-\(UUID().uuidString).mp4")
    try movie.bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try SphericalMetadata.injectFile(at: url)
    let data = try Data(contentsOf: url)
    try expect(SphericalMetadata.sphericalXML(in: data)?.contains("equirectangular") == true, "file xml")
    try expect(Int64(chunkOffset(in: data)) == movie.mdatPayloadOffset, "file stco")
}

private enum SyntheticMovie {
    static func make(moovFirst: Bool) -> (bytes: Data, mdatPayloadOffset: Int64) {
        let ftyp = box("ftyp", Data("isom".utf8) + Data([0, 0, 0, 1]) + Data("isomiso2mp41".utf8))
        let payload = Data([0x11, 0x22, 0x33, 0x44]) + Data(repeating: 0, count: 28)
        let mdat = box("mdat", payload)
        var visual = Data(count: 78)
        visual[24] = 0
        visual[25] = 64
        visual[26] = 0
        visual[27] = 32
        visual.append(box("avcC", Data([1, 100, 0, 31])))
        let avc1 = box("avc1", visual)
        var stsdBody = Data([0, 0, 0, 0, 0, 0, 0, 1])
        stsdBody.append(avc1)
        let stsd = box("stsd", stsdBody)
        let moovWithoutOffset = box("moov", box("mvhd", Data(count: 8)) + box("trak", box("mdia", box("minf", box("stbl", stsd + box("stco", Data(count: 12)))))))
        let mdatPayloadOffset: Int64 = moovFirst
            ? Int64(ftyp.count + moovWithoutOffset.count + 8)
            : Int64(ftyp.count + 8)
        let stco = box("stco", Data([0, 0, 0, 0, 0, 0, 0, 1]) + u32(UInt32(mdatPayloadOffset)))
        let moov = box("moov", box("mvhd", Data(count: 8)) + box("trak", box("mdia", box("minf", box("stbl", stsd + stco)))))
        let bytes = moovFirst ? (ftyp + moov + mdat) : (ftyp + mdat + moov)
        return (bytes, mdatPayloadOffset)
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: [UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF)])
        data.append(contentsOf: type.utf8)
        data.append(payload)
        return data
    }

    static func u32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

private func chunkOffset(in data: Data) -> UInt32 {
    let range = data.range(of: Data("stco".utf8))!
    let start = range.upperBound + 8
    return data.subdata(in: start..<(start + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func topLevelSum(_ data: Data) -> Int {
    var offset = 0
    var total = 0
    while offset + 8 <= data.count {
        let size = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        total += size
        offset += size
    }
    return total
}
