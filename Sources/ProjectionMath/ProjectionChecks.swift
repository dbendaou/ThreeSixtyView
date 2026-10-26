import Foundation

public struct CheckReport: Sendable {
    public var passed: [String]
    public var failures: [String]
    public var ok: Bool { failures.isEmpty }
}

public enum ProjectionChecks {
    public static func run() -> CheckReport {
        let cases: [(String, () throws -> Void)] = [
            ("yaw pitch roll", yawPitchAndRoll),
            ("equirect round trip", equirectRoundTrip),
            ("fisheye axis and rim", fisheyeOpticalAxisAndRim),
            ("fisheye inverse", fisheyeInverseRoundTrip),
            ("mounts", mounts),
            ("quarter turn", quarterTurnMatchesImageRotation),
            ("rotate UV", rotateUVClockwise),
            ("dual fisheye blend", dualFisheyeCoverageAndBlend),
            ("unfold centers", unfoldCenters),
            ("seg and quad", segAndQuad),
            ("panorama ring magic flat", panoramaRingAndMagicFlat),
            ("extraction tighter than front", extractionIsTighterThanFront),
            ("flat input stays original", flatInputStaysOriginal),
            ("scenic markers", scenicMarkersSurviveFrontAndYaw),
            ("drag zoom grade interpolation", dragZoomGradeAndInterpolation),
            ("drag moves every unfold", dragMovesEveryUnfold),
            ("wideshoot clip detection", wideshootClipDetection),
            ("png and export size", pngRoundTripAndSuggestion),
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
        return CheckReport(passed: passed, failures: failures)
    }
}

private struct CheckError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError(message) }
}

private func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") throws {
    if actual != expected { throw CheckError("\(message) \(actual) != \(expected)") }
}

private func near(_ actual: Float, _ expected: Float, _ accuracy: Float, _ message: String = "") throws {
    if abs(actual - expected) > accuracy {
        throw CheckError("\(message) \(actual) vs \(expected) ±\(accuracy)")
    }
}

private func nearVec(_ actual: Vec3, _ expected: Vec3, _ accuracy: Float = 1e-4) throws {
    try near(actual.x, expected.x, accuracy, "x")
    try near(actual.y, expected.y, accuracy, "y")
    try near(actual.z, expected.z, accuracy, "z")
}

private func yawPitchAndRoll() throws {
    let yaw = cameraRotation(yaw: 90.degreesToRadians, pitch: 0, roll: 0)
    try nearVec(yaw.multiply(Vec3(0, 0, 1)), Vec3(1, 0, 0))
    let pitch = cameraRotation(yaw: 0, pitch: 90.degreesToRadians, roll: 0)
    try nearVec(pitch.multiply(Vec3(0, 0, 1)), Vec3(0, 1, 0))
    let roll = cameraRotation(yaw: 0, pitch: 0, roll: 90.degreesToRadians)
    try nearVec(roll.multiply(Vec3(1, 0, 0)), Vec3(0, 1, 0))
}

private func equirectRoundTrip() throws {
    let samples = [
        Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0),
        Vec3(0, -1, 0), Vec3(0, 0, -1), Vec3(0.4, 0.2, 0.7).normalized(),
    ]
    for direction in samples {
        let uv = equirectUV(direction)
        try nearVec(directionFromEquirect(u: uv.x, v: uv.y), direction.normalized(), 1e-4)
    }
    let center = equirectUV(Vec3(0, 0, 1))
    try near(center.x, 0.5, 1e-5)
    try near(center.y, 0.5, 1e-5)
}

private func fisheyeOpticalAxisAndRim() throws {
    let lens = LensModel.sp360
    let hit = fisheyeHit(world: Vec3(0, 0, 1), lens: lens, mount: .lensForward, quarterTurns: 0, imageWidth: 200, imageHeight: 200)
    try near(hit?.u ?? -1, 0.5, 1e-5)
    try near(hit?.v ?? -1, 0.5, 1e-5)
    try near(hit?.theta ?? -1, 0, 1e-4)
    let edge = fisheyeHit(
        world: Vec3(sin(lens.fov * 0.5), 0, cos(lens.fov * 0.5)),
        lens: lens, mount: .lensForward, quarterTurns: 0, imageWidth: 200, imageHeight: 200
    )
    try near(edge?.u ?? -1, 1, 1e-3)
    try near(edge?.v ?? -1, 0.5, 1e-3)
    try expect(fisheyeHit(world: Vec3(0, 0, -1), lens: lens, mount: .lensForward, quarterTurns: 0, imageWidth: 200, imageHeight: 200) == nil, "outside")
}

private func fisheyeInverseRoundTrip() throws {
    let lens = LensModel(centerX: 0.48, centerY: 0.53, radius: 0.46, fov: 235.degreesToRadians, yaw: 0.2, pitch: -0.1, roll: 0.3)
    let directions = [Vec3(0, 0, 1), Vec3(0.2, 0.3, 0.9), Vec3(-0.4, 0.2, 0.8), Vec3(0.1, -0.5, 0.7)]
    for direction in directions {
        let world = direction.normalized()
        guard let hit = fisheyeHit(world: world, lens: lens, mount: .lensForward, quarterTurns: 1, imageWidth: 320, imageHeight: 240) else {
            throw CheckError("Expected a hit for \(world)")
        }
        let back = worldDirection(fromFisheyeU: hit.u, v: hit.v, lens: lens, mount: .lensForward, quarterTurns: 1, imageWidth: 320, imageHeight: 240)
        try nearVec(back ?? Vec3(0, 0, 0), world, 2e-4)
    }
}

private func mounts() throws {
    let lens = LensModel.sp360
    try near(fisheyeHit(world: Vec3(0, 1, 0), lens: lens, mount: .lensUp, quarterTurns: 0, imageWidth: 100, imageHeight: 100)?.theta ?? 1, 0, 1e-4)
    try near(fisheyeHit(world: Vec3(0, -1, 0), lens: lens, mount: .lensDown, quarterTurns: 0, imageWidth: 100, imageHeight: 100)?.theta ?? 1, 0, 1e-4)
    try near(fisheyeHit(world: Vec3(0, 0, 1), lens: lens, mount: .lensForward, quarterTurns: 0, imageWidth: 100, imageHeight: 100)?.theta ?? 1, 0, 1e-4)
    try expect(fisheyeHit(world: Vec3(0, -1, 0), lens: lens, mount: .lensUp, quarterTurns: 0, imageWidth: 100, imageHeight: 100) == nil, "nadir")
    let right = worldDirection(fromFisheyeU: 0.75, v: 0.5, lens: lens, mount: .lensUp, quarterTurns: 0, imageWidth: 100, imageHeight: 100)
    let turned = worldDirection(fromFisheyeU: 0.75, v: 0.5, lens: lens, mount: .lcdDown, quarterTurns: 0, imageWidth: 100, imageHeight: 100)
    try expect(right != nil && turned != nil && right!.dot(turned!) < 0.2, "LCD down roll")
}

private func quarterTurnMatchesImageRotation() throws {
    let lens = LensModel.sp360
    let turned = fisheyeHit(world: Vec3(1, 0, 0), lens: lens, mount: .lensForward, quarterTurns: 1, imageWidth: 100, imageHeight: 100)
    let plain = fisheyeHit(world: Vec3(1, 0, 0), lens: lens, mount: .lensForward, quarterTurns: 0, imageWidth: 100, imageHeight: 100)
    let rotated = rotateUV(plain!.u, plain!.v, turns: 1)
    try near(turned!.u, rotated.x, 1e-4)
    try near(turned!.v, rotated.y, 1e-4)
}

private func rotateUVClockwise() throws {
    let top = rotateUV(0.5, 0, turns: 1)
    try near(top.x, 0, 1e-5)
    try near(top.y, 0.5, 1e-5)
}

private func dualFisheyeCoverageAndBlend() throws {
    let input = InputParams.dualSideBySide()
    let front = fisheyeHit(world: Vec3(0, 0, 1), lens: input.lensA, mount: input.mount, quarterTurns: 0, imageWidth: 400, imageHeight: 200)
    let back = fisheyeHit(world: Vec3(0, 0, -1), lens: input.lensB, mount: input.mount, quarterTurns: 0, imageWidth: 400, imageHeight: 200)
    try near(front!.u, 0.25, 0.02)
    try near(back!.u, 0.75, 0.02)
    try expect(fisheyeHit(world: Vec3(0, 0, 1), lens: input.lensB, mount: input.mount, quarterTurns: 0, imageWidth: 400, imageHeight: 200) == nil, "back misses forward")
    let seam = Vec3(sin(110.degreesToRadians), 0, cos(110.degreesToRadians))
    let frontHit = fisheyeHit(world: seam, lens: input.lensA, mount: .lensForward, quarterTurns: 0, imageWidth: 400, imageHeight: 200)!
    let backHit = fisheyeHit(world: seam, lens: input.lensB, mount: .lensForward, quarterTurns: 0, imageWidth: 400, imageHeight: 200)!
    let wf = lensWeight(theta: frontHit.theta, maxTheta: frontHit.maxTheta, blend: input.blend)
    let wb = lensWeight(theta: backHit.theta, maxTheta: backHit.maxTheta, blend: input.blend)
    try expect(wb > wf && wf > 0 && wf <= 1, "blend weights")
}

private func direction(_ mode: UnfoldMode, _ x: Float, _ y: Float, _ size: Float, yaw: Float = 0) -> Vec3? {
    var view = ViewParams.standard(mode: mode)
    view.yaw = yaw
    let hit = projectionHit(view: view, quarterTurns: 0, x: x, y: y, outW: size, outH: size, sourceW: size, sourceH: size, flatInput: false)
    if case .spherical(let direction) = hit { return direction }
    return nil
}

private func unfoldCenters() throws {
    let size: Float = 101
    let mid = size / 2
    try nearVec(direction(.front16x9, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.dome, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.fisheye, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.global, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.littlePlanet, mid, mid, size)!, Vec3(0, 0, -1))
    try nearVec(direction(.throwOut, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.extraction, mid, mid, size)!, Vec3(0, 0, 1))
    try nearVec(direction(.front16x9, mid, mid, size, yaw: 90.degreesToRadians)!, Vec3(1, 0, 0))
    let dome = ViewParams.standard(mode: .dome)
    guard case .spherical(let edgeDirection) = projectionHit(view: dome, quarterTurns: 0, x: size, y: mid, outW: size, outH: size, sourceW: size, sourceH: size, flatInput: false) else {
        throw CheckError("dome edge")
    }
    try near(acos(clampUnit(edgeDirection.dot(Vec3(0, 0, 1)))), dome.domeFOV * 0.5, 0.02)
    try eq(projectionHit(view: dome, quarterTurns: 0, x: 1, y: 1, outW: size, outH: size, sourceW: size, sourceH: size, flatInput: false), .empty)
}

private func hit(_ x: Float, _ y: Float, _ view: ViewParams, _ width: Float, _ height: Float) throws -> Vec3 {
    guard case .spherical(let direction) = projectionHit(view: view, quarterTurns: 0, x: x, y: y, outW: width, outH: height, sourceW: 100, sourceH: 100, flatInput: false) else {
        throw CheckError("missing direction")
    }
    return direction
}

private func segAndQuad() throws {
    var seg = ViewParams.standard(mode: .seg)
    seg.fovY = 40.degreesToRadians
    try nearVec(try hit(50, 40, seg, 200, 80), Vec3(0, 0, 1), 1e-4)
    try nearVec(try hit(150, 40, seg, 200, 80), Vec3(0, 0, -1), 1e-4)
    let quad = ViewParams.standard(mode: .quad)
    try nearVec(try hit(50, 20, quad, 200, 80), Vec3(0, 0, 1), 1e-4)
    try nearVec(try hit(150, 20, quad, 200, 80), Vec3(1, 0, 0), 1e-4)
    try nearVec(try hit(50, 60, quad, 200, 80), Vec3(-1, 0, 0), 1e-4)
    try nearVec(try hit(150, 60, quad, 200, 80), Vec3(0, 0, -1), 1e-4)
}

private func sampleDir(_ view: ViewParams, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Vec3 {
    guard case .spherical(let direction) = projectionHit(view: view, quarterTurns: 0, x: x, y: y, outW: w, outH: h, sourceW: 10, sourceH: 10, flatInput: false) else {
        return Vec3(0, 0, 0)
    }
    return direction
}

private func panoramaRingAndMagicFlat() throws {
    let panorama = ViewParams.standard(mode: .panorama)
    let left = sampleDir(panorama, 90, 45, 360, 90)
    let right = sampleDir(panorama, 270, 45, 360, 90)
    try near(left.y, 0, 1e-3)
    try near(right.y, 0, 1e-3)
    try near(acos(clampUnit(left.dot(right))), panorama.panoramaHoriz * 0.5, 0.02)
    let magic = ViewParams.standard(mode: .magicFlat)
    try near(sampleDir(magic, 40, 40, 80, 80).y, 0, 1e-3)
    try near(acos(clampUnit(sampleDir(magic, 0, 40, 80, 80).dot(sampleDir(magic, 80, 40, 80, 80)))), magic.magicHoriz, 0.02)
    let ring = ViewParams.standard(mode: .ring)
    try eq(projectionHit(view: ring, quarterTurns: 0, x: 50, y: 50, outW: 100, outH: 100, sourceW: 10, sourceH: 10, flatInput: false), .empty)
    guard case .spherical(let ringDirection) = projectionHit(view: ring, quarterTurns: 0, x: 50, y: 8, outW: 100, outH: 100, sourceW: 10, sourceH: 10, flatInput: false) else {
        throw CheckError("ring")
    }
    try expect(abs(ringDirection.x) + abs(ringDirection.y) + abs(ringDirection.z) > 0.9, "ring length")
}

private func extractionIsTighterThanFront() throws {
    let front = ViewParams.standard(mode: .front16x9)
    var extraction = ViewParams.standard(mode: .extraction)
    extraction.fovY = 50.degreesToRadians
    func top(_ view: ViewParams) -> Float {
        guard case .spherical(let direction) = projectionHit(view: view, quarterTurns: 0, x: 50, y: 0.5, outW: 100, outH: 100, sourceW: 10, sourceH: 10, flatInput: false) else { return 0 }
        return asin(clampUnit(direction.y))
    }
    try expect(top(extraction) < top(front), "extraction fov")
}

private func flatInputStaysOriginal() throws {
    let view = ViewParams.standard(mode: .dome)
    let hit = projectionHit(view: view, quarterTurns: 0, x: 10, y: 10, outW: 100, outH: 100, sourceW: 100, sourceH: 100, flatInput: true)
    guard case .sourceUV = hit else { throw CheckError("flat files are not unfolded") }
}

private func scenicMarkersSurviveFrontAndYaw() throws {
    let source = SyntheticScene.fisheyeImage(width: 129, height: 129, lens: .sp360, mount: .lensForward)
    let input = InputParams(mode: .singleFisheye, mount: .lensForward, lensA: .sp360)
    var front = ViewParams.standard(mode: .front16x9)
    front.fovY = 30.degreesToRadians
    let red = renderFrame(source: source, back: nil, view: front, input: input, outputWidth: 41, outputHeight: 41).pixel(20, 20)
    try expect(red.0 > 180 && red.1 < 90, "red marker")
    front.yaw = 90.degreesToRadians
    let yellow = renderFrame(source: source, back: nil, view: front, input: input, outputWidth: 41, outputHeight: 41).pixel(20, 20)
    try expect(yellow.0 > 180 && yellow.1 > 150 && yellow.2 < 80, "yellow marker")
    let sky = SyntheticScene.fisheyeImage(width: 129, height: 129, lens: .sp360, mount: .lensUp).pixel(64, 64)
    try expect(sky.0 > 220 && sky.1 > 220 && sky.2 > 220, "zenith")
}

private func imagesDiffer(_ a: RGBAImage, _ b: RGBAImage) -> Bool {
    guard a.width == b.width, a.height == b.height, a.rgba.count == b.rgba.count else { return true }
    var changed = 0
    var index = 0
    while index + 2 < a.rgba.count {
        let dr = abs(Int(a.rgba[index]) - Int(b.rgba[index]))
        let dg = abs(Int(a.rgba[index + 1]) - Int(b.rgba[index + 1]))
        let db = abs(Int(a.rgba[index + 2]) - Int(b.rgba[index + 2]))
        if dr > 18 || dg > 18 || db > 18 { changed += 1 }
        index += 4
    }
    return changed >= 8
}

private func dragMovesEveryUnfold() throws {
    let suggestion = suggestInput(width: 1072, height: 1072)
    var input = suggestion.makeInput()
    input.grade.sharpnessEnabled = false
    let source = SyntheticScene.fisheyeImage(width: 128, height: 128, lens: input.lensA, mount: input.mount)
    for mode in UnfoldMode.allCases {
        var view = ViewParams.standard(mode: mode)
        let before = renderFrame(source: source, back: nil, view: view, input: input, outputWidth: 64, outputHeight: 48)
        let moved = draggedView(view, dx: 96, dy: 28, width: 240, height: 160)
        if !mode.usesSphericalDrag {
            try expect(moved.yaw == view.yaw && moved.pitch == view.pitch, "\(mode.title) keeps the raw frame")
            continue
        }
        try expect(abs(wrapRadians(moved.yaw - view.yaw)) > 0.05, "\(mode.title) yaw pans")
        try expect(abs(moved.pitch - view.pitch) > 0.02, "\(mode.title) pitch tilts")
        let afterDrag = renderFrame(source: source, back: nil, view: moved, input: input, outputWidth: 64, outputHeight: 48)
        try expect(imagesDiffer(before, afterDrag), "drag changes \(mode.title)")
        view.yaw = 80.degreesToRadians
        view.pitch = 22.degreesToRadians
        let compass = renderFrame(source: source, back: nil, view: view, input: input, outputWidth: 64, outputHeight: 48)
        try expect(imagesDiffer(before, compass), "compass and arrows change \(mode.title)")
    }
}

private func dragZoomGradeAndInterpolation() throws {
    let look = dragLook(yaw: 0, pitch: 0, dx: 10, dy: 4, sensitivity: 0.01)
    try expect(look.yaw < 0 && look.pitch < 0, "drag")
    let view = ViewParams.standard(mode: .front16x9)
    try near(view.fovY.radiansToDegrees, 100, 0.01)
    try near(zoomed(view, factor: 2).fovY, view.fovY / 2, 1e-5)
    try near(nudged(view, .center).yaw, 0, 1e-5)
    let gray = applyGrade(red: 1, green: 0, blue: 0, grade: ColorGrade(saturation: 0))
    try near(gray.0, gray.1, 1e-3)
    try near(gray.1, gray.2, 1e-3)
    let start = ViewParams.standard(mode: .front16x9)
    var end = start
    end.yaw = 10.degreesToRadians
    var wrapped = start
    wrapped.yaw = 350.degreesToRadians
    let mid = interpolatedView(samples: [DirectorSample(time: 0, view: wrapped), DirectorSample(time: 1, view: end)], time: 0.5, fallback: start)
    try near(mid.yaw.radiansToDegrees, 0, 0.05)
}

private func wideshootClipDetection() throws {
    let clip = suggestInput(width: 1072, height: 1072)
    try eq(clip.mode, .singleFisheye)
    try eq(clip.mount, .lensDown)
    try eq(clip.mount.title, "Ceiling / down")
    try eq(clip.unfold, .front16x9)
    try near(clip.fisheyeFOV.radiansToDegrees, 225, 0.01)
    try near(clip.yaw, 0, 1e-5)
    try near(clip.pitch, 0, 1e-5)
    try near(clip.makeInput().lensA.radius, 0.5, 1e-5)
    let view = clip.makeView()
    guard case .spherical(let forward) = projectionHit(view: view, quarterTurns: 0, x: 50.5, y: 50.5, outW: 101, outH: 101, sourceW: 1072, sourceH: 1072, flatInput: false) else {
        throw CheckError("opening view")
    }
    try nearVec(forward, Vec3(0, 0, 1), 1e-4)
    let lens = clip.makeInput().lensA
    try near(fisheyeHit(world: Vec3(0, -1, 0), lens: lens, mount: clip.mount, quarterTurns: 0, imageWidth: 1072, imageHeight: 1072)?.theta ?? -1, 0, 1e-4)
    try near(fisheyeHit(world: Vec3(0, 0, 1), lens: lens, mount: clip.mount, quarterTurns: 0, imageWidth: 1072, imageHeight: 1072)?.theta ?? 0, .pi / 2, 0.02)
    try eq(suggestInput(width: 3840, height: 1920).mode, .equirectangular)
    try eq(suggestInput(width: 1920, height: 960).mode, .equirectangular)
    try eq(suggestInput(width: 1072, height: 1073).mode, .singleFisheye)
    let ntsc = frameTiming(forNominalFPS: 29.97)
    try eq(ntsc.value, Int64(1001))
    try eq(ntsc.timescale, Int32(30000))
    try expect(abs(ntsc.seconds - 1001.0 / 30000.0) < 1e-9, "29.97 duration")
    try eq(frameTiming(forNominalFPS: 30000.0 / 1001.0).timescale, Int32(30000))
}

private func pngRoundTripAndSuggestion() throws {
    let image = SyntheticScene.equirectImage(width: 32, height: 16)
    try eq(try PNG.decode(PNG.encode(image)), image)
    try eq(suggestInput(width: 2880, height: 2880).mode, .singleFisheye)
    try eq(suggestInput(width: 2880, height: 2880).mount, .lensDown)
    try eq(suggestInput(width: 3840, height: 1920).mode, .equirectangular)
    try eq(suggestInput(width: 1920, height: 1080).mode, .flat)
    let size = exportPixelSize(mode: .equirect, preset: .youtube4k)
    try eq(size.width, 3840)
    try eq(size.height, 1920)
    let hd = exportPixelSize(mode: .front16x9, preset: .hd)
    try eq(hd.width, 1920)
    try eq(hd.height, 1080)
    let uhd = exportPixelSize(mode: .front16x9, preset: .uhd)
    try eq(uhd.width, 3840)
    try eq(uhd.height, 2160)
    let uhdSphere = exportPixelSize(mode: .equirect, preset: .uhd)
    try eq(uhdSphere.width, 3840)
    try eq(uhdSphere.height, 1920)
    let dome = exportPixelSize(mode: .dome, preset: .uhd)
    try eq(dome.width, 2160)
    try eq(dome.height, 2160)
    let original = exportPixelSize(mode: .front16x9, preset: .original, sourceWidth: 1072, sourceHeight: 1072)
    try eq(original.width, 1072)
    try eq(original.height, 604)
    try expect(ExportPreset.uhd.prefersHEVC && ExportPreset.youtube4k.prefersHEVC, "4K prefers HEVC")
    try expect(!ExportPreset.hd.prefersHEVC && !ExportPreset.original.prefersHEVC, "1080p stays H.264")
}
