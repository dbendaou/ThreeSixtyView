import Foundation
import ProjectionMath
import SpatialMedia
import ThreeSixtyEngine

#if os(macOS)
import ThreeSixtyEngine
#else

@main
struct ThreeSixtyViewCLI {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let code = portableSelfTest()
            exit(Int32(code))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-fixtures"),
           CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            do {
                try writeFixtures(to: directory)
                print("Wrote fixtures to \(directory.path)")
            } catch {
                fputs("Fixture write failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        print("ThreeSixtyView is a macOS app. On this platform, run: swift run ThreeSixtyView --self-test")
    }
}

#endif

func portableSelfTest() -> Int32 {
    let projection = ProjectionChecks.run()
    let spatial = SpatialChecks.run()
    let shader = ShaderSource.lintProblems()
    for name in projection.passed { print("[PASS] projection: \(name)") }
    for name in projection.failures { print("[FAIL] projection: \(name)") }
    for name in spatial.passed { print("[PASS] spatial: \(name)") }
    for name in spatial.failures { print("[FAIL] spatial: \(name)") }
    if shader.isEmpty {
        print("[PASS] shader source lint")
    } else {
        for item in shader { print("[FAIL] shader: \(item)") }
    }
    if projection.ok && spatial.ok && shader.isEmpty {
        print("SELF-TEST OK")
        return 0
    }
    print("SELF-TEST FAILED")
    return 1
}

func writeFixtures(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fisheye = SyntheticScene.fisheyeImage(width: 512, height: 512)
    try PNG.encode(fisheye).write(to: directory.appendingPathComponent("synthetic-fisheye.png"))
    let shots = directory.appendingPathComponent("screenshots")
    try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    for (name, image) in Gallery.renders(size: 480) {
        let file = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "")
        try PNG.encode(image).write(to: shots.appendingPathComponent("\(file).png"))
    }
}
