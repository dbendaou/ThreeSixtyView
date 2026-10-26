import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RGBAImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)) {
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = fill.0
            pixels[index * 4 + 1] = fill.1
            pixels[index * 4 + 2] = fill.2
            pixels[index * 4 + 3] = fill.3
        }
        self.rgba = pixels
    }

    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }

    public mutating func setPixel(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        let i = (y * width + x) * 4
        rgba[i] = r
        rgba[i + 1] = g
        rgba[i + 2] = b
        rgba[i + 3] = a
    }
}

public func applyGrade(red: Float, green: Float, blue: Float, grade: ColorGrade) -> (Float, Float, Float) {
    func tone(_ channel: Float) -> Float {
        let contrasted = (channel - 0.5) * grade.contrast + 0.5 + grade.brightness
        return clampRange(contrasted, 0, 1)
    }
    var r = tone(red)
    var g = tone(green)
    var b = tone(blue)
    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    r = clampRange(luma + (r - luma) * grade.saturation, 0, 1)
    g = clampRange(luma + (g - luma) * grade.saturation, 0, 1)
    b = clampRange(luma + (b - luma) * grade.saturation, 0, 1)
    return (r, g, b)
}

func catmullWeight(_ x: Float) -> Float {
    let ax = abs(x)
    if ax <= 1 { return (1.5 * ax - 2.5) * ax * ax + 1 }
    if ax < 2 { return ((-0.5 * ax + 2.5) * ax - 4) * ax + 2 }
    return 0
}

/// 4×4 Catmull-Rom, the same kernel the Metal shader uses. Flat regions stay flat.
func sampleCatmull(_ image: RGBAImage, u: Float, v: Float, wrapU: Bool) -> (Float, Float, Float, Float) {
    let width = Float(max(image.width, 1))
    let height = Float(max(image.height, 1))
    var x = u * width - 0.5
    let y = v * height - 0.5
    if wrapU {
        x = x.truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
    }
    let x0 = Int(floor(x))
    let y0 = Int(floor(y))
    let fx = x - Float(x0)
    let fy = y - Float(y0)

    func at(_ ix: Int, _ iy: Int) -> (Float, Float, Float, Float) {
        var sx = ix
        let sy = min(max(iy, 0), image.height - 1)
        if wrapU {
            let w = image.width
            sx = ((sx % w) + w) % w
        } else {
            sx = min(max(sx, 0), image.width - 1)
        }
        let p = image.pixel(sx, sy)
        return (Float(p.0) / 255, Float(p.1) / 255, Float(p.2) / 255, Float(p.3) / 255)
    }

    var red: Float = 0
    var green: Float = 0
    var blue: Float = 0
    var alpha: Float = 0
    var weightSum: Float = 0
    for j in -1...2 {
        let wy = catmullWeight(Float(j) - fy)
        for i in -1...2 {
            let weight = catmullWeight(Float(i) - fx) * wy
            let sample = at(x0 + i, y0 + j)
            red += sample.0 * weight
            green += sample.1 * weight
            blue += sample.2 * weight
            alpha += sample.3 * weight
            weightSum += weight
        }
    }
    let scale = 1 / max(weightSum, 1e-5)
    return (min(max(red * scale, 0), 1), min(max(green * scale, 0), 1), min(max(blue * scale, 0), 1), min(max(alpha * scale, 0), 1))
}

private func quantize(_ value: Float) -> UInt8 {
    UInt8(clamping: Int((clampRange(value, 0, 1) * 255).rounded()))
}

public func renderFrame(
    source: RGBAImage,
    back: RGBAImage?,
    view: ViewParams,
    input: InputParams,
    outputWidth: Int,
    outputHeight: Int,
    showCalibration: Bool = false
) -> RGBAImage {
    var image = RGBAImage(width: outputWidth, height: outputHeight)
    let outW = Float(outputWidth)
    let outH = Float(outputHeight)
    let flat = input.mode == .flat
    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let hit = projectionHit(
                view: view,
                quarterTurns: input.totalQuarterTurns,
                x: Float(x) + 0.5,
                y: Float(y) + 0.5,
                outW: outW,
                outH: outH,
                sourceW: Float(source.width),
                sourceH: Float(source.height),
                flatInput: flat
            )
            let color = colorForHit(hit, source: source, back: back, input: input, showCalibration: showCalibration && (flat || view.mode == .original))
            image.setPixel(x, y, quantize(color.0), quantize(color.1), quantize(color.2), quantize(color.3))
        }
    }
    if input.grade.sharpnessEnabled && input.grade.sharpness > 0.001 {
        image = sharpen(image, amount: input.grade.sharpness)
    }
    return image
}

func colorForHit(
    _ hit: ProjectionHit,
    source: RGBAImage,
    back: RGBAImage?,
    input: InputParams,
    showCalibration: Bool
) -> (Float, Float, Float, Float) {
    switch hit {
    case .empty:
        return (0, 0, 0, 255)
    case .sourceUV(let uv):
        var sample = sampleCatmull(source, u: uv.x, v: uv.y, wrapU: false)
        if showCalibration && onCalibrationRing(uv: uv, lens: input.lensA, width: source.width, height: source.height) {
            sample = (0.92, 0.18, 0.16, 1)
        }
        let graded = applyGrade(red: sample.0, green: sample.1, blue: sample.2, grade: input.grade)
        return (graded.0, graded.1, graded.2, sample.3)
    case .spherical(let direction):
        guard let sample = sampleSphere(direction, source: source, back: back, input: input) else {
            return (0, 0, 0, 255)
        }
        let graded = applyGrade(red: sample.0, green: sample.1, blue: sample.2, grade: input.grade)
        return (graded.0, graded.1, graded.2, sample.3)
    }
}

func onCalibrationRing(uv: Vec2, lens: LensModel, width: Int, height: Int) -> Bool {
    let scales = fisheyeScales(radius: lens.radius, imageWidth: width, imageHeight: height)
    let nx = (uv.x - lens.centerX) / max(scales.sx, 1e-5)
    let ny = (lens.centerY - uv.y) / max(scales.sy, 1e-5)
    let r = hypot(nx, ny)
    return abs(r - 1) < 0.02
}

func sampleSphere(
    _ direction: Vec3,
    source: RGBAImage,
    back: RGBAImage?,
    input: InputParams
) -> (Float, Float, Float, Float)? {
    switch input.mode {
    case .flat:
        return nil
    case .equirectangular:
        let uv = equirectUV(direction)
        return sampleCatmull(source, u: uv.x, v: uv.y, wrapU: true)
    case .singleFisheye:
        guard let hit = fisheyeHit(
            world: direction, lens: input.lensA, mount: input.mount,
            quarterTurns: input.userQuarterTurns,
            imageWidth: source.width, imageHeight: source.height
        ) else { return nil }
        return sampleCatmull(source, u: hit.u, v: hit.v, wrapU: false)
    case .dualSideBySide, .dualTwoFiles:
        let secondImage = input.mode == .dualTwoFiles ? (back ?? source) : source
        let first = lensSample(direction, image: source, lens: input.lensA, input: input)
        let second = lensSample(direction, image: secondImage, lens: input.lensB, input: input)
        return blend(first, second, blend: input.blend)
    }
}

private struct LensSample {
    var color: (Float, Float, Float, Float)
    var theta: Float
    var maxTheta: Float
    var valid: Bool
}

private func lensSample(_ direction: Vec3, image: RGBAImage, lens: LensModel, input: InputParams) -> LensSample {
    guard let hit = fisheyeHit(
        world: direction, lens: lens, mount: input.mount,
        quarterTurns: input.userQuarterTurns,
        imageWidth: image.width, imageHeight: image.height
    ) else {
        return LensSample(color: (0, 0, 0, 1), theta: 0, maxTheta: 1, valid: false)
    }
    let color = sampleCatmull(image, u: hit.u, v: hit.v, wrapU: false)
    return LensSample(color: color, theta: hit.theta, maxTheta: hit.maxTheta, valid: true)
}

private func blend(_ a: LensSample, _ b: LensSample, blend: Float) -> (Float, Float, Float, Float)? {
    if !a.valid && !b.valid { return nil }
    if !a.valid { return b.color }
    if !b.valid { return a.color }
    let wa = lensWeight(theta: a.theta, maxTheta: a.maxTheta, blend: blend)
    let wb = lensWeight(theta: b.theta, maxTheta: b.maxTheta, blend: blend)
    let sum = wa + wb
    if sum < 1e-5 {
        return (
            (a.color.0 + b.color.0) * 0.5,
            (a.color.1 + b.color.1) * 0.5,
            (a.color.2 + b.color.2) * 0.5,
            1
        )
    }
    func mix(_ i: Float, _ j: Float) -> Float { (i * wa + j * wb) / sum }
    return (mix(a.color.0, b.color.0), mix(a.color.1, b.color.1), mix(a.color.2, b.color.2), 1)
}

func sharpen(_ image: RGBAImage, amount: Float) -> RGBAImage {
    var output = image
    let w = image.width
    let h = image.height
    func channel(_ pixel: (UInt8, UInt8, UInt8, UInt8), _ index: Int) -> Float {
        switch index {
        case 0: return Float(pixel.0)
        case 1: return Float(pixel.1)
        default: return Float(pixel.2)
        }
    }
    for y in 0..<h {
        for x in 0..<w {
            let center = image.pixel(x, y)
            let neighbors = [
                image.pixel(max(x - 1, 0), y),
                image.pixel(min(x + 1, w - 1), y),
                image.pixel(x, max(y - 1, 0)),
                image.pixel(x, min(y + 1, h - 1)),
            ]
            var out = [UInt8](repeating: 255, count: 3)
            for i in 0..<3 {
                let c = channel(center, i)
                let blur = neighbors.reduce(Float(0)) { $0 + channel($1, i) } * 0.25
                out[i] = quantize((c + amount * (c - blur)) / 255)
            }
            output.setPixel(x, y, out[0], out[1], out[2], 255)
        }
    }
    return output
}
