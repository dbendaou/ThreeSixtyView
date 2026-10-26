import Foundation

public enum SyntheticScene {
    public static func color(for direction: Vec3) -> (UInt8, UInt8, UInt8) {
        let n = direction.normalized()
        let markers: [(Vec3, UInt8, UInt8, UInt8)] = [
            (Vec3(0, 0, 1), 220, 40, 40),
            (Vec3(0, 0, -1), 40, 200, 200),
            (Vec3(1, 0, 0), 230, 200, 40),
            (Vec3(-1, 0, 0), 40, 80, 220),
            (Vec3(0, 1, 0), 245, 245, 245),
            (Vec3(0, -1, 0), 20, 180, 60),
        ]
        let limit = cos(8 * Float.pi / 180)
        for marker in markers where n.dot(marker.0) >= limit {
            return (marker.1, marker.2, marker.3)
        }
        let horizon = (r: Float(210), g: Float(170), b: Float(130))
        if n.y >= 0 {
            let sky = (r: Float(150), g: Float(190), b: Float(230))
            return mix(horizon, sky, n.y)
        }
        let ground = (r: Float(70), g: Float(120), b: Float(60))
        return mix(horizon, ground, -n.y)
    }

    public static func fisheyeImage(
        width: Int,
        height: Int,
        lens: LensModel = .sp360,
        mount: MountOrientation = .lensDown,
        quarterTurns: Int = 0
    ) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)
                guard let direction = worldDirection(
                    fromFisheyeU: u, v: v, lens: lens, mount: mount,
                    quarterTurns: quarterTurns, imageWidth: width, imageHeight: height
                ) else {
                    continue
                }
                let color = color(for: direction)
                image.setPixel(x, y, color.0, color.1, color.2, 255)
            }
        }
        return image
    }

    public static func equirectImage(width: Int, height: Int) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)
                let color = color(for: directionFromEquirect(u: u, v: v))
                image.setPixel(x, y, color.0, color.1, color.2, 255)
            }
        }
        return image
    }

    public static func encodeDirection(_ direction: Vec3) -> (UInt8, UInt8, UInt8) {
        let n = direction.normalized()
        func q(_ value: Float) -> UInt8 {
            UInt8(clamping: Int(((value * 0.5 + 0.5) * 255).rounded()))
        }
        return (q(n.x), q(n.y), q(n.z))
    }

    public static func decodeDirection(r: UInt8, g: UInt8, b: UInt8) -> Vec3 {
        func f(_ channel: UInt8) -> Float { Float(channel) / 255 * 2 - 1 }
        return Vec3(f(r), f(g), f(b)).normalized()
    }

    private static func mix(
        _ a: (r: Float, g: Float, b: Float),
        _ b: (r: Float, g: Float, b: Float),
        _ t: Float
    ) -> (UInt8, UInt8, UInt8) {
        func q(_ value: Float) -> UInt8 { UInt8(clamping: Int(value.rounded())) }
        return (
            q(a.r + (b.r - a.r) * t),
            q(a.g + (b.g - a.g) * t),
            q(a.b + (b.b - a.b) * t)
        )
    }
}

public enum Gallery {
    public static func renders(size: Int = 360) -> [(String, RGBAImage)] {
        let source = SyntheticScene.fisheyeImage(width: 512, height: 512, lens: .sp360, mount: .lensDown)
        let input = InputParams.sp360Dome()
        let modes: [UnfoldMode] = [
            .dome, .fisheye, .front16x9, .seg, .quad, .panorama,
            .ring, .magicFlat, .global, .littlePlanet, .equirect, .throwOut,
        ]
        return modes.map { mode in
            let view = ViewParams.standard(mode: mode)
            let aspect = mode.preferredAspect
            let width = aspect >= 1 ? size : max(2, Int((Float(size) * aspect).rounded()))
            let height = aspect >= 1 ? max(2, Int((Float(size) / aspect).rounded())) : size
            let image = renderFrame(
                source: source, back: nil, view: view, input: input,
                outputWidth: width, outputHeight: height
            )
            return (mode.title, image)
        }
    }
}
