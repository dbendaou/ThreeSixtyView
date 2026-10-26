import Foundation
import ProjectionMath
import SpatialMedia

/// Linux CI entry point. Builds and runs only ProjectionMath and SpatialMedia.
@main
enum PortableChecks {
    static func main() {
        let projection = ProjectionChecks.run()
        let spatial = SpatialChecks.run()
        for name in projection.passed { print("[PASS] projection: \(name)") }
        for name in projection.failures { print("[FAIL] projection: \(name)") }
        for name in spatial.passed { print("[PASS] spatial: \(name)") }
        for name in spatial.failures { print("[FAIL] spatial: \(name)") }
        if projection.ok && spatial.ok {
            print("SELF-TEST OK")
            return
        }
        print("SELF-TEST FAILED")
        exit(1)
    }
}
