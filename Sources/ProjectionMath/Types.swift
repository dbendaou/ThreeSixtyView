import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct Vec2: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }
}

public struct Vec3: Equatable, Sendable, CustomStringConvertible {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float, _ y: Float, _ z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var length: Float { (x * x + y * y + z * z).squareRoot() }

    public func normalized() -> Vec3 {
        let l = length
        if l < 1e-8 { return Vec3(0, 0, 1) }
        return Vec3(x / l, y / l, z / l)
    }

    public func dot(_ other: Vec3) -> Float {
        x * other.x + y * other.y + z * other.z
    }

    public func cross(_ other: Vec3) -> Vec3 {
        Vec3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    public static func * (lhs: Vec3, rhs: Float) -> Vec3 {
        Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    public static prefix func - (v: Vec3) -> Vec3 { Vec3(-v.x, -v.y, -v.z) }

    public var description: String {
        String(format: "(%.5f, %.5f, %.5f)", x, y, z)
    }
}

/// Row-major 3×3. `multiply` applies the matrix on the left of a column vector.
public struct Mat3: Equatable, Sendable {
    public var r0: Vec3
    public var r1: Vec3
    public var r2: Vec3

    public init(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.r0 = r0
        self.r1 = r1
        self.r2 = r2
    }

    public static let identity = Mat3(
        rows: Vec3(1, 0, 0),
        Vec3(0, 1, 0),
        Vec3(0, 0, 1)
    )

    public func multiply(_ v: Vec3) -> Vec3 {
        Vec3(r0.dot(v), r1.dot(v), r2.dot(v))
    }

    public var transpose: Mat3 {
        Mat3(
            rows: Vec3(r0.x, r1.x, r2.x),
            Vec3(r0.y, r1.y, r2.y),
            Vec3(r0.z, r1.z, r2.z)
        )
    }

    public func multiply(_ other: Mat3) -> Mat3 {
        let b = other.transpose
        func row(_ r: Vec3) -> Vec3 {
            Vec3(r.dot(b.r0), r.dot(b.r1), r.dot(b.r2))
        }
        return Mat3(rows: row(r0), row(r1), row(r2))
    }
}

public func clampUnit(_ value: Float) -> Float { min(max(value, -1), 1) }

public func clampRange(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(value, lo), hi)
}

public extension Float {
    var degreesToRadians: Float { self * .pi / 180 }
    var radiansToDegrees: Float { self * 180 / .pi }
}

public extension Int {
    var degreesToRadians: Float { Float(self) * .pi / 180 }
}

public func wrapDegrees(_ degrees: Float) -> Float {
    var x = degrees.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x <= -180 { x += 360 }
    return x
}

public func wrapRadians(_ radians: Float) -> Float {
    var x = radians.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x <= -.pi { x += 2 * .pi }
    return x
}

/// Shortest-path interpolation of angles in radians.
public func lerpAngle(_ a: Float, _ b: Float, _ t: Float) -> Float {
    var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    return wrapRadians(a + delta * t)
}

/// Camera rotation. Yaw about +Y, pitch about +X (positive looks up), roll about +Z.
/// The unrotated camera looks down +Z, with +Y up and +X right.
public func cameraRotation(yaw: Float, pitch: Float, roll: Float) -> Mat3 {
    let cy = cos(yaw), sy = sin(yaw)
    let cp = cos(pitch), sp = sin(pitch)
    let cr = cos(roll), sr = sin(roll)
    let ry = Mat3(rows: Vec3(cy, 0, sy), Vec3(0, 1, 0), Vec3(-sy, 0, cy))
    let rx = Mat3(rows: Vec3(1, 0, 0), Vec3(0, cp, sp), Vec3(0, -sp, cp))
    let rz = Mat3(rows: Vec3(cr, -sr, 0), Vec3(sr, cr, 0), Vec3(0, 0, 1))
    return ry.multiply(rx).multiply(rz)
}
