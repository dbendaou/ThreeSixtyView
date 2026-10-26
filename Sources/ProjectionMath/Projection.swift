import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// How the source file is projected onto the sphere.
public enum InputMode: Int32, CaseIterable, Sendable, Codable {
    /// Already-stitched 2:1 equirectangular (VR-Global / YouTube).
    case equirectangular = 0
    /// One circular fisheye. Wideshoot / SP360 clips are this, about 225°.
    case singleFisheye = 1
    /// Two circular fisheyes packed left/right in one frame.
    case dualSideBySide = 2
    /// Two files, each a circular fisheye (SP360 dual-camera rig).
    case dualTwoFiles = 3
    /// Ordinary flat video or a Front-mode file that cannot be unfolded.
    case flat = 4

    public var title: String {
        switch self {
        case .equirectangular: return "Equirectangular"
        case .singleFisheye: return "Single fisheye"
        case .dualSideBySide: return "Dual fisheye (side by side)"
        case .dualTwoFiles: return "Dual fisheye (two files)"
        case .flat: return "Flat"
        }
    }
}

/// Mount / "View Mode" in the SP360 software: which way the lens faced.
public enum MountOrientation: Int32, CaseIterable, Sendable, Codable {
    case lensForward = 0
    case lensDown = 1
    case lensUp = 2
    case lcdDown = 3
    case lcdUp = 4

    public var title: String {
        switch self {
        case .lensForward: return "Lens forward"
        case .lensDown: return "Ceiling / down"
        case .lensUp: return "Lens up"
        case .lcdDown: return "LCD down"
        case .lcdUp: return "LCD up"
        }
    }

    /// Optical axis before the LCD 180° roll.
    public var base: MountOrientation {
        switch self {
        case .lensForward: return .lensForward
        case .lensDown, .lcdUp: return .lensDown
        case .lensUp, .lcdDown: return .lensUp
        }
    }

    /// Extra quarter-turns of the circular image (LCD facing flips the body 180°).
    public var extraQuarterTurns: Int {
        switch self {
        case .lcdDown, .lcdUp: return 2
        default: return 0
        }
    }

    /// Maps a direction in lens space (+Z optical axis, +X right, +Y up) into world space.
    public var lensToWorld: Mat3 {
        switch base {
        case .lensForward:
            return .identity
        case .lensUp:
            // Optical axis → world up. Image up → world −Z.
            return Mat3(rows: Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, -1, 0))
        case .lensDown:
            // Optical axis → world down. Image up → world +Z.
            return Mat3(rows: Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0))
        case .lcdDown, .lcdUp:
            return base.lensToWorld
        }
    }
}

/// Unfold modes from the PIXPRO SP360 4K playback software, plus little planet
/// and an explicit fisheye re-projection (VR-mode Fish-Eye / Wideshoot dome).
public enum UnfoldMode: Int32, CaseIterable, Sendable, Codable, Identifiable {
    case original = 0
    case dome = 1
    case fisheye = 2
    case front16x9 = 3
    case front4x3 = 4
    case seg = 5
    case quad = 6
    case panorama = 7
    case ring = 8
    case magicFlat = 9
    case global = 10
    case littlePlanet = 11
    case equirect = 12
    case extraction = 13
    case throwOut = 14

    public var id: Int32 { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .dome: return "Dome"
        case .fisheye: return "Fisheye"
        case .front16x9: return "Front 16:9"
        case .front4x3: return "Front 4:3"
        case .seg: return "Seg"
        case .quad: return "Quad"
        case .panorama: return "Panorama"
        case .ring: return "Ring"
        case .magicFlat: return "Magic Flat"
        case .global: return "Global"
        case .littlePlanet: return "Little Planet"
        case .equirect: return "Equirect"
        case .extraction: return "Extraction"
        case .throwOut: return "Throw-out"
        }
    }

    public var detail: String {
        switch self {
        case .original: return "Source frame, for calibration and Front-mode files"
        case .dome: return "Circular dome, equidistant fisheye"
        case .fisheye: return "Front fisheye you can aim"
        case .front16x9: return "Rectilinear view, 16:9"
        case .front4x3: return "Rectilinear view, 4:3"
        case .seg: return "Front and back, side by side"
        case .quad: return "Four directions"
        case .panorama: return "360° horizontal band"
        case .ring: return "Horizon wrapped into a ring"
        case .magicFlat: return "Wide cylindrical dewarp"
        case .global: return "Stereographic globe"
        case .littlePlanet: return "Tiny planet"
        case .equirect: return "Full equirectangular sphere"
        case .extraction: return "Tighter rectilinear extract"
        case .throwOut: return "Bulging stereographic fill"
        }
    }

    /// Width / height used when exporting this unfold into a frame.
    public var preferredAspect: Float {
        switch self {
        case .front4x3: return 4.0 / 3.0
        case .equirect: return 2
        case .seg: return 32.0 / 9.0
        case .dome, .fisheye, .global, .littlePlanet, .ring, .original: return 1
        case .quad, .front16x9, .panorama, .magicFlat, .extraction, .throwOut:
            return 16.0 / 9.0
        }
    }

    public var usesSphericalDrag: Bool { self != .original }
}

public struct LensModel: Equatable, Sendable, Codable {
    /// Center of the circle, 0...1 across the source image.
    public var centerX: Float
    public var centerY: Float
    /// Radius as a fraction of min(width, height). 0.5 touches the shorter side.
    public var radius: Float
    /// Full field of view, radians. Wideshoot roof clips fill the square at about 225°.
    public var fov: Float
    /// Extra aim of this lens, radians, applied in the mount frame.
    public var yaw: Float
    public var pitch: Float
    public var roll: Float

    public init(
        centerX: Float = 0.5,
        centerY: Float = 0.5,
        radius: Float = 0.5,
        fov: Float = 225 * .pi / 180,
        yaw: Float = 0,
        pitch: Float = 0,
        roll: Float = 0
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.radius = radius
        self.fov = fov
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let sp360 = LensModel()

    public static func dualLeft() -> LensModel {
        LensModel(centerX: 0.25)
    }

    public static func dualRight() -> LensModel {
        LensModel(centerX: 0.75, yaw: .pi)
    }
}

public struct ColorGrade: Equatable, Sendable, Codable {
    public var brightness: Float
    public var contrast: Float
    public var saturation: Float
    public var sharpness: Float
    public var sharpnessEnabled: Bool

    public init(
        brightness: Float = 0,
        contrast: Float = 1,
        saturation: Float = 1,
        sharpness: Float = 0.35,
        sharpnessEnabled: Bool = true
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.sharpness = sharpness
        self.sharpnessEnabled = sharpnessEnabled
    }

    public static let identity = ColorGrade()
}

public struct InputParams: Equatable, Sendable, Codable {
    public var mode: InputMode
    public var mount: MountOrientation
    /// Wideshoot "rotation vidéo": 0, 1, 2, or 3 clockwise quarter-turns.
    public var userQuarterTurns: Int
    public var lensA: LensModel
    public var lensB: LensModel
    /// Overlap blend width for dual fisheye, radians.
    public var blend: Float
    public var grade: ColorGrade

    public init(
        mode: InputMode = .singleFisheye,
        mount: MountOrientation = .lensDown,
        userQuarterTurns: Int = 0,
        lensA: LensModel = .sp360,
        lensB: LensModel = .dualRight(),
        blend: Float = 15 * .pi / 180,
        grade: ColorGrade = .identity
    ) {
        self.mode = mode
        self.mount = mount
        self.userQuarterTurns = userQuarterTurns
        self.lensA = lensA
        self.lensB = lensB
        self.blend = blend
        self.grade = grade
    }

    public var totalQuarterTurns: Int {
        userQuarterTurns + mount.extraQuarterTurns
    }

    public static func sp360Dome() -> InputParams { InputParams() }

    public static func equirect() -> InputParams {
        InputParams(mode: .equirectangular, mount: .lensForward)
    }

    public static func dualSideBySide() -> InputParams {
        InputParams(
            mode: .dualSideBySide,
            mount: .lensForward,
            lensA: .dualLeft(),
            lensB: .dualRight()
        )
    }
}

public struct ViewParams: Equatable, Sendable, Codable {
    public var mode: UnfoldMode
    public var yaw: Float
    public var pitch: Float
    public var roll: Float
    /// Rectilinear vertical field of view (Front, Seg, Quad, Extraction).
    public var fovY: Float
    public var domeFOV: Float
    public var fisheyeOutFOV: Float
    public var planetScale: Float
    public var panoramaHoriz: Float
    public var panoramaVert: Float
    public var magicHoriz: Float
    public var magicVert: Float
    public var ringInner: Float
    public var ringLat0: Float
    public var ringLatSpan: Float
    public var throwScale: Float
    /// Seg right-hand view, added to yaw. Default 180°.
    public var segYawOffset: Float

    public init(
        mode: UnfoldMode = .dome,
        yaw: Float = 0,
        pitch: Float = 0,
        roll: Float = 0,
        fovY: Float = 100 * .pi / 180,
        domeFOV: Float = 225 * .pi / 180,
        fisheyeOutFOV: Float = 180 * .pi / 180,
        planetScale: Float = 1.15,
        panoramaHoriz: Float = 2 * .pi,
        panoramaVert: Float = 110 * .pi / 180,
        magicHoriz: Float = .pi,
        magicVert: Float = .pi / 2,
        ringInner: Float = 0.38,
        ringLat0: Float = -55 * .pi / 180,
        ringLatSpan: Float = 110 * .pi / 180,
        throwScale: Float = 0.65,
        segYawOffset: Float = .pi
    ) {
        self.mode = mode
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.fovY = fovY
        self.domeFOV = domeFOV
        self.fisheyeOutFOV = fisheyeOutFOV
        self.planetScale = planetScale
        self.panoramaHoriz = panoramaHoriz
        self.panoramaVert = panoramaVert
        self.magicHoriz = magicHoriz
        self.magicVert = magicVert
        self.ringInner = ringInner
        self.ringLat0 = ringLat0
        self.ringLatSpan = ringLatSpan
        self.throwScale = throwScale
        self.segYawOffset = segYawOffset
    }

    public static func standard(mode: UnfoldMode = .dome) -> ViewParams {
        var view = ViewParams()
        view.mode = mode
        if mode == .extraction {
            view.fovY = 50 * .pi / 180
        }
        return view
    }

    public var rotation: Mat3 {
        cameraRotation(yaw: yaw, pitch: pitch, roll: roll)
    }

    public func withYaw(offset: Float) -> ViewParams {
        var copy = self
        copy.yaw += offset
        return copy
    }
}

public enum Nudge: Equatable, Sendable {
    case yaw(Float)
    case pitch(Float)
    case roll(Float)
    /// Values greater than 1 zoom in.
    case zoom(Float)
    case center
}

public func nudged(_ view: ViewParams, _ nudge: Nudge) -> ViewParams {
    var view = view
    switch nudge {
    case .yaw(let degrees):
        view.yaw = wrapRadians(view.yaw + degrees.degreesToRadians)
    case .pitch(let degrees):
        view.pitch = clampRange(view.pitch + degrees.degreesToRadians, -89.degreesToRadians, 89.degreesToRadians)
    case .roll(let degrees):
        view.roll = wrapRadians(view.roll + degrees.degreesToRadians)
    case .zoom(let factor):
        view = zoomed(view, factor: factor)
    case .center:
        let mode = view.mode
        let keptFov = view.fovY
        view = ViewParams.standard(mode: mode)
        if mode != .extraction {
            view.fovY = keptFov
        }
        // Center restores aim and the mode's primary zoom, not a custom extraction field.
        if mode == .front16x9 || mode == .front4x3 || mode == .seg || mode == .quad {
            view.fovY = 100 * .pi / 180
        }
        _ = keptFov
    }
    return view
}

public func zoomed(_ view: ViewParams, factor: Float) -> ViewParams {
    var view = view
    let safe = max(factor, 0.05)
    switch view.mode {
    case .dome:
        view.domeFOV = clampRange(view.domeFOV / safe, 20.degreesToRadians, 270.degreesToRadians)
    case .fisheye:
        view.fisheyeOutFOV = clampRange(view.fisheyeOutFOV / safe, 20.degreesToRadians, 270.degreesToRadians)
    case .global, .littlePlanet:
        view.planetScale = clampRange(view.planetScale / safe, 0.15, 8)
    case .panorama:
        view.panoramaVert = clampRange(view.panoramaVert / safe, 10.degreesToRadians, .pi)
    case .ring:
        view.ringLatSpan = clampRange(view.ringLatSpan / safe, 10.degreesToRadians, .pi)
    case .magicFlat:
        view.magicHoriz = clampRange(view.magicHoriz / safe, 30.degreesToRadians, 2 * .pi)
    case .throwOut:
        view.throwScale = clampRange(view.throwScale / safe, 0.05, 3)
    case .original:
        break
    case .front16x9, .front4x3, .seg, .quad, .extraction, .equirect:
        view.fovY = clampRange(view.fovY / safe, 10.degreesToRadians, 140.degreesToRadians)
    }
    return view
}

public enum ProjectionHit: Equatable, Sendable {
    case spherical(Vec3)
    case sourceUV(Vec2)
    case empty
}

public func letterbox(contentAspect: Float, outW: Float, outH: Float) -> (x: Float, y: Float, w: Float, h: Float) {
    let viewAspect = outW / max(outH, 1e-4)
    if contentAspect > viewAspect {
        let w = outW
        let h = outW / contentAspect
        return (0, (outH - h) * 0.5, w, h)
    } else {
        let h = outH
        let w = outH * contentAspect
        return ((outW - w) * 0.5, 0, w, h)
    }
}

/// Clockwise quarter-turns of the displayed image.
public func rotateUV(_ u: Float, _ v: Float, turns: Int) -> Vec2 {
    switch normalizedTurns(turns) {
    case 1: return Vec2(v, 1 - u)
    case 2: return Vec2(1 - u, 1 - v)
    case 3: return Vec2(1 - v, u)
    default: return Vec2(u, v)
    }
}

/// Inverse of `rotateUV`. A logical upright coordinate is recovered from a rotated file.
public func unrotateUV(_ u: Float, _ v: Float, turns: Int) -> Vec2 {
    switch normalizedTurns(turns) {
    case 1: return Vec2(1 - v, u)
    case 2: return Vec2(1 - u, 1 - v)
    case 3: return Vec2(v, 1 - u)
    default: return Vec2(u, v)
    }
}

private func normalizedTurns(_ turns: Int) -> Int {
    ((turns % 4) + 4) % 4
}

public func originalMapping(
    x: Float,
    y: Float,
    outW: Float,
    outH: Float,
    sourceW: Float,
    sourceH: Float,
    turns: Int
) -> Vec2? {
    let aspect = sourceW / max(sourceH, 1)
    let rect = letterbox(contentAspect: aspect, outW: outW, outH: outH)
    if x < rect.x || y < rect.y || x > rect.x + rect.w || y > rect.y + rect.h {
        return nil
    }
    let u = (x - rect.x) / max(rect.w, 1e-4)
    let v = (y - rect.y) / max(rect.h, 1e-4)
    return rotateUV(u, v, turns: turns)
}

private func rectilinear(x: Float, y: Float, w: Float, h: Float, fovY: Float, rotation: Mat3) -> Vec3 {
    let ndcX = (x / w) * 2 - 1
    let ndcY = 1 - (y / h) * 2
    let aspect = w / max(h, 1e-4)
    let t = tan(fovY * 0.5)
    let camera = Vec3(ndcX * aspect * t, ndcY * t, 1).normalized()
    return rotation.multiply(camera)
}

private func circularFisheye(x: Float, y: Float, w: Float, h: Float, fov: Float, rotation: Mat3) -> Vec3? {
    let cx = w * 0.5
    let cy = h * 0.5
    let radius = min(w, h) * 0.5
    let dx = x - cx
    let dy = cy - y
    let r = hypot(dx, dy)
    if r > radius { return nil }
    let theta = (r / max(radius, 1e-5)) * (fov * 0.5)
    let phi = atan2(dy, dx)
    let camera = Vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
    return rotation.multiply(camera)
}

private func stereographicGlobe(x: Float, y: Float, w: Float, h: Float, scale: Float, rotation: Mat3, littlePlanet: Bool) -> Vec3? {
    let cx = w * 0.5
    let cy = h * 0.5
    let radius = min(w, h) * 0.5
    let dx = x - cx
    let dy = cy - y
    let r = hypot(dx, dy)
    if r > radius { return nil }
    let rho = (r / max(radius, 1e-5)) * scale
    let theta = littlePlanet ? (.pi - 2 * atan(rho)) : (2 * atan(rho))
    let phi = atan2(dy, dx)
    let camera = Vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
    return rotation.multiply(camera)
}

private func latLonBand(x: Float, y: Float, w: Float, h: Float, horiz: Float, vert: Float, rotation: Mat3) -> Vec3? {
    let lon = (x / w - 0.5) * horiz
    let lat = (0.5 - y / h) * vert
    if lat < -.pi / 2 || lat > .pi / 2 { return nil }
    let camera = Vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    return rotation.multiply(camera)
}

private func cylindrical(x: Float, y: Float, w: Float, h: Float, horiz: Float, vert: Float, rotation: Mat3) -> Vec3 {
    let ndcX = (x / w) * 2 - 1
    let ndcY = 1 - (y / h) * 2
    let lon = ndcX * horiz * 0.5
    let yv = ndcY * tan(vert * 0.5)
    let camera = Vec3(sin(lon), yv, cos(lon)).normalized()
    return rotation.multiply(camera)
}

private func ringDirection(x: Float, y: Float, w: Float, h: Float, inner: Float, lat0: Float, latSpan: Float, rotation: Mat3) -> Vec3? {
    let cx = w * 0.5
    let cy = h * 0.5
    let outer = min(w, h) * 0.5
    let dx = x - cx
    let dy = cy - y
    let r = hypot(dx, dy)
    let innerR = outer * clampRange(inner, 0.05, 0.95)
    if r < innerR || r > outer { return nil }
    let t = (r - innerR) / max(outer - innerR, 1e-5)
    let lat = lat0 + t * latSpan
    if lat < -.pi / 2 || lat > .pi / 2 { return nil }
    let lon = atan2(dx, dy)
    let camera = Vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    return rotation.multiply(camera)
}

private func throwOutDirection(x: Float, y: Float, w: Float, h: Float, scale: Float, rotation: Mat3) -> Vec3 {
    let ndcX = (x / w) * 2 - 1
    let ndcY = 1 - (y / h) * 2
    let aspect = w / max(h, 1e-4)
    let px = ndcX * aspect
    let py = ndcY
    let rho = hypot(px, py) * scale
    let theta = 2 * atan(rho)
    let phi = atan2(py, px)
    let camera = Vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
    return rotation.multiply(camera)
}

private struct Tile {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
    var yawOffset: Float
}

private func tile(mode: UnfoldMode, x: Float, y: Float, w: Float, h: Float, segYawOffset: Float) -> Tile {
    switch mode {
    case .seg:
        let half = w * 0.5
        if x < half {
            return Tile(x: x, y: y, w: half, h: h, yawOffset: 0)
        }
        return Tile(x: x - half, y: y, w: w - half, h: h, yawOffset: segYawOffset)
    case .quad:
        let hw = w * 0.5
        let hh = h * 0.5
        let col = x < hw ? 0 : 1
        let row = y < hh ? 0 : 1
        let localX = x - Float(col) * hw
        let localY = y - Float(row) * hh
        let localW = col == 0 ? hw : w - hw
        let localH = row == 0 ? hh : h - hh
        // Reading order: front, right, left, back.
        let offsets: [Float] = [0, 90, 270, 180]
        let yaw = offsets[row * 2 + col].degreesToRadians
        return Tile(x: localX, y: localY, w: localW, h: localH, yawOffset: yaw)
    default:
        return Tile(x: x, y: y, w: w, h: h, yawOffset: 0)
    }
}

/// `x` and `y` are continuous pixel coordinates (pixel i has center i+0.5).
public func projectionHit(
    view: ViewParams,
    quarterTurns: Int,
    x: Float,
    y: Float,
    outW: Float,
    outH: Float,
    sourceW: Float,
    sourceH: Float,
    flatInput: Bool
) -> ProjectionHit {
    if flatInput || view.mode == .original {
        if let uv = originalMapping(
            x: x, y: y, outW: outW, outH: outH,
            sourceW: sourceW, sourceH: sourceH, turns: quarterTurns
        ) {
            return .sourceUV(uv)
        }
        return .empty
    }

    let tile = tile(mode: view.mode, x: x, y: y, w: outW, h: outH, segYawOffset: view.segYawOffset)
    let aimed = view.withYaw(offset: tile.yawOffset)
    let rotation = aimed.rotation
    let direction: Vec3?
    switch view.mode {
    case .original:
        direction = nil
    case .dome:
        direction = circularFisheye(x: tile.x, y: tile.y, w: tile.w, h: tile.h, fov: view.domeFOV, rotation: rotation)
    case .fisheye:
        direction = circularFisheye(x: tile.x, y: tile.y, w: tile.w, h: tile.h, fov: view.fisheyeOutFOV, rotation: rotation)
    case .front16x9, .front4x3, .seg, .quad, .extraction:
        direction = rectilinear(x: tile.x, y: tile.y, w: tile.w, h: tile.h, fovY: aimed.fovY, rotation: rotation)
    case .panorama:
        direction = latLonBand(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            horiz: view.panoramaHoriz, vert: view.panoramaVert, rotation: rotation
        )
    case .ring:
        direction = ringDirection(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            inner: view.ringInner, lat0: view.ringLat0, latSpan: view.ringLatSpan, rotation: rotation
        )
    case .magicFlat:
        direction = cylindrical(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            horiz: view.magicHoriz, vert: view.magicVert, rotation: rotation
        )
    case .global:
        direction = stereographicGlobe(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            scale: view.planetScale, rotation: rotation, littlePlanet: false
        )
    case .littlePlanet:
        direction = stereographicGlobe(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            scale: view.planetScale, rotation: rotation, littlePlanet: true
        )
    case .equirect:
        direction = latLonBand(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            horiz: 2 * .pi, vert: .pi, rotation: rotation
        )
    case .throwOut:
        direction = throwOutDirection(
            x: tile.x, y: tile.y, w: tile.w, h: tile.h,
            scale: view.throwScale, rotation: rotation
        )
    }
    if let direction {
        return .spherical(direction.normalized())
    }
    return .empty
}

public struct FisheyeHit: Equatable, Sendable {
    public var u: Float
    public var v: Float
    public var theta: Float
    public var maxTheta: Float
}

public func fisheyeScales(radius: Float, imageWidth: Int, imageHeight: Int) -> (sx: Float, sy: Float) {
    let aspect = Float(imageWidth) / Float(max(imageHeight, 1))
    let sx = radius * min(1, 1 / aspect)
    let sy = radius * min(aspect, 1)
    return (sx, sy)
}

public func fisheyeHit(
    world: Vec3,
    lens: LensModel,
    mount: MountOrientation,
    quarterTurns: Int,
    imageWidth: Int,
    imageHeight: Int
) -> FisheyeHit? {
    let mountSpace = mount.lensToWorld.transpose.multiply(world.normalized())
    let offset = cameraRotation(yaw: lens.yaw, pitch: lens.pitch, roll: lens.roll)
    let local = offset.transpose.multiply(mountSpace)
    let theta = acos(clampUnit(local.z))
    let maxTheta = max(lens.fov * 0.5, 1e-4)
    if theta > maxTheta + 1e-4 { return nil }
    let rNorm = min(theta / maxTheta, 1)
    let phi = atan2(local.y, local.x)
    let scales = fisheyeScales(radius: lens.radius, imageWidth: imageWidth, imageHeight: imageHeight)
    let logicalU = lens.centerX + rNorm * scales.sx * cos(phi)
    let logicalV = lens.centerY - rNorm * scales.sy * sin(phi)
    let uv = rotateUV(logicalU, logicalV, turns: quarterTurns + mount.extraQuarterTurns)
    return FisheyeHit(u: uv.x, v: uv.y, theta: theta, maxTheta: maxTheta)
}

public func worldDirection(
    fromFisheyeU u: Float,
    v: Float,
    lens: LensModel,
    mount: MountOrientation,
    quarterTurns: Int,
    imageWidth: Int,
    imageHeight: Int
) -> Vec3? {
    let scales = fisheyeScales(radius: lens.radius, imageWidth: imageWidth, imageHeight: imageHeight)
    if scales.sx < 1e-6 || scales.sy < 1e-6 { return nil }
    let logical = unrotateUV(u, v, turns: quarterTurns + mount.extraQuarterTurns)
    let nx = (logical.x - lens.centerX) / scales.sx
    let ny = (lens.centerY - logical.y) / scales.sy
    let rNorm = hypot(nx, ny)
    if rNorm > 1.0005 { return nil }
    let theta = rNorm * lens.fov * 0.5
    let phi = atan2(ny, nx)
    let local = Vec3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
    let offset = cameraRotation(yaw: lens.yaw, pitch: lens.pitch, roll: lens.roll)
    let world = mount.lensToWorld.multiply(offset.multiply(local))
    return world.normalized()
}

public func equirectUV(_ direction: Vec3) -> Vec2 {
    let d = direction.normalized()
    let lon = atan2(d.x, d.z)
    let lat = asin(clampUnit(d.y))
    return Vec2(lon / (2 * .pi) + 0.5, 0.5 - lat / .pi)
}

public func directionFromEquirect(u: Float, v: Float) -> Vec3 {
    let lon = (u - 0.5) * 2 * .pi
    let lat = (0.5 - v) * .pi
    return Vec3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
}

public func lensWeight(theta: Float, maxTheta: Float, blend: Float) -> Float {
    if theta > maxTheta { return 0 }
    if blend <= 1e-5 { return 1 }
    let inner = max(0, maxTheta - blend)
    if theta <= inner { return 1 }
    let t = (theta - inner) / max(maxTheta - inner, 1e-5)
    let smooth = t * t * (3 - 2 * t)
    return 1 - smooth
}

public struct ExportPreset: Sendable, Hashable, CaseIterable, Identifiable {
    public static func == (lhs: ExportPreset, rhs: ExportPreset) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
    public var id: String { name }
    public var name: String
    public var longSide: Int
    /// Fit the unfold's aspect inside this box. Nil uses `longSide` or `forcedEquirect`.
    public var fixedBox: (Int, Int)?
    public var forcedEquirect: (Int, Int)?
    /// Use the source frame's long side, keeping the unfold's aspect.
    public var usesSourceSize: Bool

    public var prefersHEVC: Bool {
        let wide = max(fixedBox?.0 ?? 0, forcedEquirect?.0 ?? 0, longSide)
        return wide >= 3840
    }

    public static let original = ExportPreset(name: "Original", longSide: 0, fixedBox: nil, forcedEquirect: nil, usesSourceSize: true)
    public static let hd = ExportPreset(name: "1080p", longSide: 1920, fixedBox: (1920, 1080), forcedEquirect: nil, usesSourceSize: false)
    public static let qhd = ExportPreset(name: "1440p", longSide: 2560, fixedBox: (2560, 1440), forcedEquirect: nil, usesSourceSize: false)
    public static let uhd = ExportPreset(name: "4K UHD", longSide: 3840, fixedBox: (3840, 2160), forcedEquirect: nil, usesSourceSize: false)
    public static let youtube4k = ExportPreset(name: "4K 360", longSide: 3840, fixedBox: nil, forcedEquirect: (3840, 1920), usesSourceSize: false)
    public static let youtube2880 = ExportPreset(name: "YouTube 2880×1440", longSide: 2880, fixedBox: nil, forcedEquirect: (2880, 1440), usesSourceSize: false)
    public static let youtube1920 = ExportPreset(name: "YouTube 1920×960", longSide: 1920, fixedBox: nil, forcedEquirect: (1920, 960), usesSourceSize: false)

    public static var allCases: [ExportPreset] {
        [.original, .hd, .qhd, .uhd, .youtube4k]
    }
}

public func exportPixelSize(
    mode: UnfoldMode,
    preset: ExportPreset,
    sourceWidth: Int = 0,
    sourceHeight: Int = 0
) -> (width: Int, height: Int) {
    if let forced = preset.forcedEquirect {
        return evenDimensions(forced.0, forced.1)
    }
    if preset.usesSourceSize {
        let longSide = max(max(sourceWidth, sourceHeight), 2)
        return evenSize(aspect: mode.preferredAspect, longSide: longSide)
    }
    if let box = preset.fixedBox {
        return fitInside(aspect: mode.preferredAspect, boxWidth: box.0, boxHeight: box.1)
    }
    return evenSize(aspect: mode.preferredAspect, longSide: max(preset.longSide, 2))
}

private func evenSize(aspect: Float, longSide: Int) -> (width: Int, height: Int) {
    let aspect = max(aspect, 0.01)
    let width: Int
    let height: Int
    if aspect >= 1 {
        width = longSide
        height = Int((Float(longSide) / aspect).rounded())
    } else {
        height = longSide
        width = Int((Float(longSide) * aspect).rounded())
    }
    return evenDimensions(width, height)
}

private func fitInside(aspect: Float, boxWidth: Int, boxHeight: Int) -> (width: Int, height: Int) {
    let aspect = max(aspect, 0.01)
    let boxAspect = Float(boxWidth) / Float(max(boxHeight, 1))
    let width: Int
    let height: Int
    if aspect >= boxAspect {
        width = boxWidth
        height = Int((Float(boxWidth) / aspect).rounded())
    } else {
        height = boxHeight
        width = Int((Float(boxHeight) * aspect).rounded())
    }
    return evenDimensions(width, height)
}

private func evenDimensions(_ width: Int, _ height: Int) -> (width: Int, height: Int) {
    var width = width
    var height = height
    if width % 2 != 0 { width += 1 }
    if height % 2 != 0 { height += 1 }
    return (max(width, 2), max(height, 2))
}

public func defaultVideoBitrate(width: Int, height: Int, hevc: Bool) -> Int {
    let bitsPerPixel: Float = hevc ? 0.10 : 0.18
    let bits = Float(width * height) * bitsPerPixel * 30
    return max(Int(bits), 1_000_000)
}

public struct DirectorSample: Equatable, Sendable, Codable {
    public var time: Double
    public var view: ViewParams

    public init(time: Double, view: ViewParams) {
        self.time = time
        self.view = view
    }
}

public func interpolatedView(samples: [DirectorSample], time: Double, fallback: ViewParams) -> ViewParams {
    guard let first = samples.first else { return fallback }
    if time <= first.time || samples.count == 1 { return first.view }
    guard let last = samples.last else { return fallback }
    if time >= last.time { return last.view }
    var previous = first
    for sample in samples.dropFirst() {
        if time <= sample.time {
            let span = sample.time - previous.time
            let t = span <= 1e-6 ? 0 : Float((time - previous.time) / span)
            var view = sample.view
            view.mode = previous.view.mode
            if sample.view.mode != previous.view.mode && t >= 0.999 {
                view.mode = sample.view.mode
            }
            view.yaw = lerpAngle(previous.view.yaw, sample.view.yaw, t)
            view.pitch = lerpAngle(previous.view.pitch, sample.view.pitch, t)
            view.roll = lerpAngle(previous.view.roll, sample.view.roll, t)
            view.fovY = previous.view.fovY + (sample.view.fovY - previous.view.fovY) * t
            view.domeFOV = previous.view.domeFOV + (sample.view.domeFOV - previous.view.domeFOV) * t
            view.planetScale = previous.view.planetScale + (sample.view.planetScale - previous.view.planetScale) * t
            return view
        }
        previous = sample
    }
    return last.view
}

/// Drag the picture: dragging right turns the view left (the image follows the pointer).
public func dragLook(yaw: Float, pitch: Float, dx: Float, dy: Float, sensitivity: Float) -> (yaw: Float, pitch: Float) {
    let nextYaw = wrapRadians(yaw - dx * sensitivity)
    let nextPitch = clampRange(pitch - dy * sensitivity, -89.degreesToRadians, 89.degreesToRadians)
    return (nextYaw, nextPitch)
}

/// Radians of yaw per point, so a drag across `span` covers the horizontal field.
/// Equirect, panorama, ring, dome, and planet all pan; Original does not.
public func horizontalSensitivity(_ view: ViewParams, span: Float) -> Float {
    let width = max(span, 1)
    switch view.mode {
    case .original:
        return 0
    case .equirect, .ring:
        return (2 * .pi) / width
    case .panorama:
        return max(view.panoramaHoriz, 0.2) / width
    case .magicFlat:
        return max(view.magicHoriz, 0.2) / width
    case .dome, .fisheye:
        return max(view.mode == .dome ? view.domeFOV : view.fisheyeOutFOV, 0.3) / width
    case .global, .littlePlanet, .throwOut:
        return (2 * .pi) / width
    case .front16x9, .front4x3, .seg, .quad, .extraction:
        let aspect: Float
        switch view.mode {
        case .front4x3: aspect = 4.0 / 3.0
        case .seg: aspect = 32.0 / 9.0
        default: aspect = 16.0 / 9.0
        }
        let horizontal = 2 * atan(tan(view.fovY * 0.5) * aspect)
        return max(horizontal, 0.2) / width
    }
}

public func verticalSensitivity(_ view: ViewParams, span: Float) -> Float {
    let height = max(span, 1)
    switch view.mode {
    case .original:
        return 0
    case .equirect:
        return .pi / height
    case .panorama:
        return max(view.panoramaVert, 0.2) / height
    case .magicFlat:
        return max(view.magicVert, 0.2) / height
    case .front16x9, .front4x3, .seg, .quad, .extraction:
        return max(view.fovY, 0.2) / height
    default:
        return horizontalSensitivity(view, span: span)
    }
}

/// Apply one drag sample. `dx`/`dy` use the AppKit-flipped look convention
/// (positive dx is a drag to the right, positive dy is a drag down).
public func draggedView(_ view: ViewParams, dx: Float, dy: Float, width: Float, height: Float) -> ViewParams {
    guard view.mode.usesSphericalDrag else { return view }
    var view = view
    view.yaw = wrapRadians(view.yaw - dx * horizontalSensitivity(view, span: width))
    view.pitch = clampRange(view.pitch - dy * verticalSensitivity(view, span: height), -89.degreesToRadians, 89.degreesToRadians)
    return view
}

/// What a file's pixel size implies, before the user overrides it.
/// Square frames from the Wideshoot / Fun Media clips are a circular fisheye
/// that fills the picture. 2:1 frames are already equirectangular.
public struct InputSuggestion: Equatable, Sendable {
    public var mode: InputMode
    public var unfold: UnfoldMode
    public var mount: MountOrientation
    /// Lens field of view in radians. Used when `mode` is a fisheye.
    public var fisheyeFOV: Float
    /// Opening aim. Zero yaw and pitch looks forward, along world +Z.
    public var yaw: Float
    public var pitch: Float

    public init(
        mode: InputMode,
        unfold: UnfoldMode,
        mount: MountOrientation,
        fisheyeFOV: Float,
        yaw: Float = 0,
        pitch: Float = 0
    ) {
        self.mode = mode
        self.unfold = unfold
        self.mount = mount
        self.fisheyeFOV = fisheyeFOV
        self.yaw = yaw
        self.pitch = pitch
    }

    public func makeInput() -> InputParams {
        var input = InputParams(mode: mode, mount: mount)
        input.lensA.fov = fisheyeFOV
        input.lensB.fov = fisheyeFOV
        return input
    }

    public func makeView() -> ViewParams {
        var view = ViewParams.standard(mode: unfold)
        view.yaw = yaw
        view.pitch = pitch
        return view
    }
}

/// 29.97 fps is 1001/30000, not 1/30. 59.94 is 1001/60000.
public struct FrameTiming: Equatable, Sendable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var seconds: Double { Double(value) / Double(timescale) }
}

public func frameTiming(forNominalFPS fps: Double) -> FrameTiming {
    if abs(fps - 29.97) < 0.03 || abs(fps - (30000.0 / 1001.0)) < 0.01 {
        return FrameTiming(value: 1001, timescale: 30000)
    }
    if abs(fps - 59.94) < 0.05 || abs(fps - (60000.0 / 1001.0)) < 0.02 {
        return FrameTiming(value: 1001, timescale: 60000)
    }
    let scale = Int32(max(1, min(Int(fps.rounded()), 60000)))
    return FrameTiming(value: 1, timescale: max(scale, 1))
}

public func suggestInput(width: Int, height: Int) -> InputSuggestion {
    let aspect = Float(width) / Float(max(height, 1))
    let wideshootFOV = Float(225).degreesToRadians
    if aspect > 0.92 && aspect < 1.08 {
        // 1072×1072 H.264 from a roof mount: the circle fills the square and the lens points down.
        // The opening view stays level, looking forward, rather than down at the roof.
        return InputSuggestion(
            mode: .singleFisheye,
            unfold: .front16x9,
            mount: .lensDown,
            fisheyeFOV: wideshootFOV,
            yaw: 0,
            pitch: 0
        )
    }
    if aspect > 1.85 && aspect < 2.15 {
        return InputSuggestion(
            mode: .equirectangular,
            unfold: .front16x9,
            mount: .lensForward,
            fisheyeFOV: wideshootFOV,
            yaw: 0,
            pitch: 0
        )
    }
    return InputSuggestion(
        mode: .flat,
        unfold: .original,
        mount: .lensForward,
        fisheyeFOV: wideshootFOV,
        yaw: 0,
        pitch: 0
    )
}
