import Foundation
#if os(macOS)
import AVFoundation
import CoreMedia
import Metal
import ProjectionMath
import SpatialMedia

public enum MacRoundTrip {
    public static func runAll() async throws {
        let stride = MemoryLayout<GPUUniforms>.stride
        guard stride == 192 else {
            throw ExportFailure.writer("GPUUniforms stride is \(stride), expected 192. The Metal shader would read the wrong fields.")
        }
        let lint = ShaderSource.lintProblems()
        if !lint.isEmpty {
            throw ExportFailure.writer("Metal shader source lint failed: \(lint.joined(separator: "; "))")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalRenderError.noDevice
        }
        let renderer = try MetalRenderer(device: device)
        print("[PASS] metal shader compiles")
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("threesixty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lens = LensModel.sp360
        let frame = SyntheticScene.fisheyeImage(width: 96, height: 96, lens: lens, mount: .lensForward)
        var tone = [Int16](repeating: 0, count: 4800)
        for index in tone.indices {
            let t = Double(index) / 48_000
            tone[index] = Int16(sin(t * 2 * Double.pi * 440) * 8000)
        }
        let sourceURL = directory.appendingPathComponent("synthetic.mp4")
        try await MovieExporter.writeFrames([frame, frame, frame, frame], fps: 30, output: sourceURL, audioPCM: tone)
        let source = AVURLAsset(url: sourceURL)
        let duration = try await source.load(.duration)
        let video = try await source.loadTracks(withMediaType: .video)
        let audio = try await source.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.count == 1, duration.seconds > 0.05 else {
            throw ExportFailure.writer("Synthetic movie is missing video, audio, or duration (\(duration.seconds)s)")
        }
        let decoded = try await firstFrame(of: source)
        guard decoded.width == 96, decoded.height == 96 else {
            throw ExportFailure.writer("Decoded synthetic frame is \(decoded.width)x\(decoded.height)")
        }
        let center = decoded.pixel(decoded.width / 2, decoded.height / 2)
        guard center.0 > 160, center.1 < 90 else {
            throw ExportFailure.writer("Synthetic center pixel is \(center), expected the red +Z marker")
        }
        print("[PASS] synthetic H.264 movie with audio round-trips")

        var view = ViewParams.standard(mode: .front16x9)
        view.fovY = 30.degreesToRadians
        let input = InputParams(mode: .singleFisheye, mount: .lensForward, lensA: lens)
        let flatURL = directory.appendingPathComponent("flat.mp4")
        let flat = ExportJob(
            outputURL: flatURL, width: 48, height: 48, bitrate: 4_000_000, includeAudio: true,
            useMetal: false, view: view, input: input, fileURL: sourceURL
        )
        try await MovieExporter.export(flat)
        let flatAsset = AVURLAsset(url: flatURL)
        guard try await flatAsset.loadTracks(withMediaType: .audio).isEmpty == false else {
            throw ExportFailure.writer("Flat export dropped the audio track")
        }
        let flatFrame = try await firstFrame(of: flatAsset)
        let flatCenter = flatFrame.pixel(flatFrame.width / 2, flatFrame.height / 2)
        guard flatCenter.0 > 150, flatCenter.1 < 100 else {
            throw ExportFailure.writer("Flat export center is \(flatCenter), expected red")
        }
        print("[PASS] flat reprojected export keeps the aimed marker and audio")

        var equirectView = ViewParams.standard(mode: .equirect)
        equirectView.yaw = 0
        equirectView.pitch = 0
        equirectView.roll = 0
        let equirectURL = directory.appendingPathComponent("equirect.mp4")
        let equirect = ExportJob(
            outputURL: equirectURL, width: 64, height: 32, bitrate: 4_000_000, includeAudio: false,
            injectSpherical: true, useMetal: false, view: equirectView, input: input, fileURL: sourceURL
        )
        try await MovieExporter.export(equirect)
        let equirectData = try Data(contentsOf: equirectURL)
        guard let xml = SphericalMetadata.sphericalXML(in: equirectData),
              xml.contains("equirectangular"), xml.contains("GSpherical:Spherical>true"),
              SphericalMetadata.containsEquirectangularSV3D(equirectData) else {
            throw ExportFailure.writer("Equirect export is missing Spatial Media metadata")
        }
        let equirectFrame = try await firstFrame(of: AVURLAsset(url: equirectURL))
        guard equirectFrame.width == 64, equirectFrame.height == 32 else {
            throw ExportFailure.writer("Equirect frame is \(equirectFrame.width)x\(equirectFrame.height) after metadata injection")
        }
        print("[PASS] equirect export is readable and carries spherical metadata")

        let cancelURL = directory.appendingPathComponent("cancel.mp4")
        let token = ExportCancellation()
        token.cancel()
        let cancelJob = ExportJob(
            outputURL: cancelURL, width: 32, height: 32, useMetal: false, view: view, input: input, fileURL: sourceURL
        )
        do {
            try await MovieExporter.export(cancelJob, cancel: token)
            throw ExportFailure.writer("Cancelled export should fail")
        } catch ExportFailure.cancelled {
            print("[PASS] cancel stops an export")
        }

        let stillURL = directory.appendingPathComponent("still.jpg")
        let rendered = renderFrame(source: frame, back: nil, view: view, input: input, outputWidth: 32, outputHeight: 32)
        try MovieExporter.writeStill(rendered, to: stillURL, format: .jpeg, jpegQuality: 0.9)
        let reloaded = try MovieExporter.loadImage(stillURL)
        guard reloaded.width == 32, reloaded.pixel(16, 16).0 > 140 else {
            throw ExportFailure.image("JPEG still did not round-trip")
        }
        print("[PASS] JPEG still round-trips")

        guard let texture = renderer.upload(frame) else { throw MetalRenderError.texture }
        let uniforms = GPUUniforms.make(
            view: view, input: input, sourceWidth: 96, sourceHeight: 96,
            backWidth: 1, backHeight: 1, outputWidth: 41, outputHeight: 41,
            hasBack: false, showCalibration: false
        )
        let gpu = try renderer.renderReadback(source: texture, back: nil, uniforms: uniforms, width: 41, height: 41)
        let cpu = renderFrame(source: frame, back: nil, view: view, input: input, outputWidth: 41, outputHeight: 41)
        let gpuPixel = gpu.pixel(20, 20)
        let cpuPixel = cpu.pixel(20, 20)
        for (g, c) in [(gpuPixel.0, cpuPixel.0), (gpuPixel.1, cpuPixel.1), (gpuPixel.2, cpuPixel.2)] {
            if abs(Int(g) - Int(c)) > 8 {
                throw ExportFailure.writer("Metal pixel \(gpuPixel) differs from CPU \(cpuPixel)")
            }
        }
        print("[PASS] Metal front view matches the CPU projection")

        let hevcURL = directory.appendingPathComponent("hevc.mp4")
        do {
            try await MovieExporter.writeFrames([frame], fps: 30, output: hevcURL, codec: .hevc, bitrate: 4_000_000)
            let hevc = AVURLAsset(url: hevcURL)
            guard try await hevc.loadTracks(withMediaType: .video).isEmpty == false else {
                throw ExportFailure.writer("HEVC file has no video")
            }
            print("[PASS] HEVC encoder writes a readable movie")
        } catch {
            print("[SKIP] HEVC: \(error)")
        }
        print("MAC ROUND TRIP OK")
    }

    private static func firstFrame(of asset: AVAsset) async throws -> RGBAImage {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportFailure.noVideo }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw ExportFailure.read("Can't read the exported movie") }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ExportFailure.read(reader.error?.localizedDescription ?? "No decoded frame")
        }
        return readRGBA(buffer)
    }
}
#endif
