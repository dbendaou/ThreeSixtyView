import Foundation
#if os(macOS)
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AudioToolbox
import ProjectionMath
import SpatialMedia

public enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc
    public var id: String { rawValue }
    public var title: String { self == .hevc ? "HEVC" : "H.264" }
    var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

public enum StillFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    public var id: String { rawValue }
    public var title: String { self == .png ? "PNG" : "JPEG" }
}

public enum ExportFailure: Error, CustomStringConvertible {
    case noVideo
    case cancelled
    case writer(String)
    case read(String)
    case image(String)

    public var description: String {
        switch self {
        case .noVideo: return "This file has no video track."
        case .cancelled: return "Export cancelled."
        case .writer(let message): return message
        case .read(let message): return message
        case .image(let message): return message
        }
    }
}

public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    public func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

public struct ExportJob: @unchecked Sendable {
    public var outputURL: URL
    public var width: Int
    public var height: Int
    public var codec: VideoCodec
    public var bitrate: Int
    public var includeAudio: Bool
    public var injectSpherical: Bool
    public var useMetal: Bool
    public var view: ViewParams
    public var input: InputParams
    public var director: [DirectorSample]
    public var showCalibration: Bool
    public var fileURL: URL?
    public var rangeStart: Double?
    public var rangeEnd: Double?
    public var backImage: RGBAImage?
    public var sequenceFPS: Double
    public var sequenceFrames: [RGBAImage]

    public init(
        outputURL: URL,
        width: Int,
        height: Int,
        codec: VideoCodec = .h264,
        bitrate: Int? = nil,
        includeAudio: Bool = true,
        injectSpherical: Bool = false,
        useMetal: Bool = true,
        view: ViewParams,
        input: InputParams,
        director: [DirectorSample] = [],
        showCalibration: Bool = false,
        fileURL: URL? = nil,
        rangeStart: Double? = nil,
        rangeEnd: Double? = nil,
        backImage: RGBAImage? = nil,
        sequenceFPS: Double = 30,
        sequenceFrames: [RGBAImage] = []
    ) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate ?? defaultVideoBitrate(width: width, height: height, hevc: codec == .hevc)
        self.includeAudio = includeAudio
        self.injectSpherical = injectSpherical
        self.useMetal = useMetal
        self.view = view
        self.input = input
        self.director = director
        self.showCalibration = showCalibration
        self.fileURL = fileURL
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.backImage = backImage
        self.sequenceFPS = sequenceFPS
        self.sequenceFrames = sequenceFrames
    }
}

public enum MovieExporter {
    public static func export(
        _ job: ExportJob,
        cancel: ExportCancellation = ExportCancellation(),
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        if cancel.isCancelled { throw ExportFailure.cancelled }
        let width = job.width - job.width % 2
        let height = job.height - job.height % 2
        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            try FileManager.default.removeItem(at: job.outputURL)
        }
        if let fileURL = job.fileURL {
            try await exportFile(job, width: width, height: height, fileURL: fileURL, cancel: cancel, progress: progress)
        } else {
            try await exportSequence(job, width: width, height: height, cancel: cancel, progress: progress)
        }
        if job.injectSpherical {
            try SphericalMetadata.injectFile(at: job.outputURL, software: "ThreeSixtyView")
        }
        progress(1)
    }

    public static func writeFrames(
        _ images: [RGBAImage],
        fps: Int32,
        output: URL,
        codec: VideoCodec = .h264,
        bitrate: Int = 8_000_000,
        audioPCM: [Int16]? = nil,
        sampleRate: Double = 48_000
    ) async throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        guard let first = images.first else { throw ExportFailure.image("No frames") }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(
            codec: codec, width: first.width, height: first.height, bitrate: bitrate, fps: Double(fps)
        ))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelAttributes(width: first.width, height: first.height))
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioPCM, !audioPCM.isEmpty {
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings(sampleRate: sampleRate))
            audioInput?.expectsMediaDataInRealTime = false
            if let audioInput, writer.canAdd(audioInput) { writer.add(audioInput) }
        }
        guard writer.startWriting() else {
            throw ExportFailure.writer(writer.error?.localizedDescription ?? "Could not start the encoder")
        }
        writer.startSession(atSourceTime: .zero)
        for (index, image) in images.enumerated() {
            guard let buffer = makePixelBuffer(width: image.width, height: image.height, metal: false) else {
                throw ExportFailure.writer("Could not allocate a frame")
            }
            writeBGRA(image, into: buffer)
            while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw ExportFailure.writer(writer.error?.localizedDescription ?? "Could not append a frame")
            }
        }
        videoInput.markAsFinished()
        if let audioInput, let audioPCM {
            if let sample = pcmSampleBuffer(samples: audioPCM, sampleRate: sampleRate) {
                while !audioInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                if !audioInput.append(sample) {
                    throw ExportFailure.writer(writer.error?.localizedDescription ?? "Could not append audio")
                }
            }
            audioInput.markAsFinished()
        }
        try await finish(writer)
    }

    public static func trim(source: URL, start: Double?, end: Double?, output: URL) async throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportFailure.writer("Can't trim this file")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        if let start, let end, end > start {
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600)
            )
        }
        try await exportSession(session)
    }

    public static func join(urls: [URL], output: URL) async throws {
        if urls.isEmpty { throw ExportFailure.read("Add at least one clip") }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportFailure.writer("Couldn't open a joined video track")
        }
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let source = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
            }
            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportFailure.writer("Couldn't join these clips")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        try await exportSession(session)
    }

    public static func writeStill(_ image: RGBAImage, to url: URL, format: StillFormat, jpegQuality: Float) throws {
        let data = Data(image.rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { throw ExportFailure.image("Couldn't encode the still") }
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmap,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw ExportFailure.image("Couldn't encode the still") }
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportFailure.image("Couldn't create \(url.lastPathComponent)")
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, format == .jpeg ? properties : nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportFailure.image("Couldn't write the still") }
    }

    public static func loadImage(_ url: URL) throws -> RGBAImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportFailure.image("Couldn't read \(url.lastPathComponent)")
        }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ExportFailure.image("Couldn't draw \(url.lastPathComponent)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBAImage(width: width, height: height, rgba: pixels)
    }
}

private extension MovieExporter {
    static func exportFile(
        _ job: ExportJob,
        width: Int,
        height: Int,
        fileURL: URL,
        cancel: ExportCancellation,
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: fileURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ExportFailure.noVideo }
        let duration = try await asset.load(.duration)
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominal = try await videoTrack.load(.nominalFrameRate)
        let fps = nominal > 1 ? Double(nominal) : (30000.0 / 1001.0)
        let minFrame = try await videoTrack.load(.minFrameDuration)
        let timing = (minFrame.isValid && minFrame.seconds > 0.001 && minFrame.seconds < 0.5)
            ? FrameTiming(value: minFrame.value, timescale: minFrame.timescale)
            : frameTiming(forNominalFPS: fps)
        let oriented = orientedSize(natural, transform)
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: max(2, abs(oriented.width)), height: max(2, abs(oriented.height)))
        composition.frameDuration = CMTime(value: timing.value, timescale: timing.timescale)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let startSeconds = max(0, job.rangeStart ?? 0)
        let endSeconds = min(duration.seconds, job.rangeEnd ?? duration.seconds)
        let span = max(1.0 / fps, endSeconds - startSeconds)
        let range = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: span, preferredTimescale: 600)
        )
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: bgraSettings)
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = true
        guard reader.canAdd(videoOutput) else { throw ExportFailure.read("Can't decode this video") }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw ExportFailure.read(reader.error?.localizedDescription ?? "The decoder didn't start")
        }

        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(
            codec: job.codec, width: width, height: height, bitrate: job.bitrate, fps: fps
        ))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttributes(width: width, height: height)
        )
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if job.includeAudio, let prepared = try await preparedAudioInput(asset: asset), writer.canAdd(prepared) {
            writer.add(prepared)
            audioInput = prepared
        }
        guard writer.startWriting() else {
            throw ExportFailure.writer(writer.error?.localizedDescription ?? "The encoder didn't start")
        }
        writer.startSession(atSourceTime: .zero)
        let renderer = job.useMetal ? try MetalRenderer() : nil
        var backTexture: MTLTexture?
        if let backImage = job.backImage, let renderer {
            backTexture = renderer.upload(backImage)
        }
        let expected = max(1, Int((span * fps).rounded()))
        var frameIndex = 0
        while true {
            if cancel.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: job.outputURL)
                throw ExportFailure.cancelled
            }
            guard let sample = videoOutput.copyNextSampleBuffer(), let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { break }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let zero = CMTimeSubtract(timestamp, range.start)
            let frameView = job.director.isEmpty
                ? job.view
                : interpolatedView(samples: job.director, time: CMTimeGetSeconds(timestamp), fallback: job.view)
            guard let rendered = renderJobFrame(
                sourceBuffer: sourceBuffer,
                view: frameView,
                input: job.input,
                backImage: job.backImage,
                backTexture: backTexture,
                renderer: renderer,
                width: width,
                height: height,
                showCalibration: job.showCalibration
            ) else { throw ExportFailure.writer("Couldn't render a frame") }
            while !videoInput.isReadyForMoreMediaData {
                if cancel.isCancelled { throw ExportFailure.cancelled }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if !adaptor.append(rendered, withPresentationTime: zero) {
                throw ExportFailure.writer(writer.error?.localizedDescription ?? "Couldn't write a frame")
            }
            frameIndex += 1
            progress(min(0.98, Double(frameIndex) / Double(expected)))
        }
        if reader.status == .failed {
            throw ExportFailure.read(reader.error?.localizedDescription ?? "Decoding failed")
        }
        videoInput.markAsFinished()
        if let audioInput {
            try await appendAudio(from: asset, range: range, to: audioInput)
        }
        try await finish(writer)
    }

    static func exportSequence(
        _ job: ExportJob,
        width: Int,
        height: Int,
        cancel: ExportCancellation,
        progress: @escaping (Double) -> Void
    ) async throws {
        let frames = job.sequenceFrames
        guard !frames.isEmpty else { throw ExportFailure.image("Nothing to export") }
        let fps = Int32(max(1.0, job.sequenceFPS.rounded()))
        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(
            codec: job.codec, width: width, height: height, bitrate: job.bitrate, fps: Double(fps)
        ))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttributes(width: width, height: height)
        )
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw ExportFailure.writer(writer.error?.localizedDescription ?? "The encoder didn't start")
        }
        writer.startSession(atSourceTime: .zero)
        let renderer = job.useMetal ? try MetalRenderer() : nil
        var backTexture: MTLTexture?
        if let backImage = job.backImage, let renderer { backTexture = renderer.upload(backImage) }
        for (index, image) in frames.enumerated() {
            if cancel.isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: job.outputURL)
                throw ExportFailure.cancelled
            }
            guard let buffer = makePixelBuffer(width: image.width, height: image.height, metal: renderer != nil) else {
                throw ExportFailure.writer("Couldn't allocate a frame")
            }
            writeBGRA(image, into: buffer)
            let time = Double(index) / Double(fps)
            let frameView = job.director.isEmpty ? job.view : interpolatedView(samples: job.director, time: time, fallback: job.view)
            guard let rendered = renderJobFrame(
                sourceBuffer: buffer, view: frameView, input: job.input, backImage: job.backImage,
                backTexture: backTexture, renderer: renderer, width: width, height: height, showCalibration: job.showCalibration
            ) else { throw ExportFailure.writer("Couldn't render a frame") }
            while !videoInput.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            if !adaptor.append(rendered, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) {
                throw ExportFailure.writer(writer.error?.localizedDescription ?? "Couldn't write a frame")
            }
            progress(min(0.98, Double(index + 1) / Double(frames.count)))
        }
        videoInput.markAsFinished()
        try await finish(writer)
    }

    static func renderJobFrame(
        sourceBuffer: CVPixelBuffer,
        view: ViewParams,
        input: InputParams,
        backImage: RGBAImage?,
        backTexture: MTLTexture?,
        renderer: MetalRenderer?,
        width: Int,
        height: Int,
        showCalibration: Bool
    ) -> CVPixelBuffer? {
        guard let renderer else {
            let source = readRGBA(sourceBuffer)
            let image = renderFrame(
                source: source, back: backImage, view: view, input: input,
                outputWidth: width, outputHeight: height, showCalibration: showCalibration
            )
            guard let buffer = makePixelBuffer(width: width, height: height, metal: false) else { return nil }
            writeBGRA(image, into: buffer)
            return buffer
        }
        let sourceTexture = renderer.texture(from: sourceBuffer) ?? renderer.upload(readRGBA(sourceBuffer))
        guard let sourceTexture,
              let buffer = makePixelBuffer(width: width, height: height, metal: true) else { return nil }
        let uniforms = GPUUniforms.make(
            view: view, input: input,
            sourceWidth: CVPixelBufferGetWidth(sourceBuffer),
            sourceHeight: CVPixelBufferGetHeight(sourceBuffer),
            backWidth: backImage?.width ?? CVPixelBufferGetWidth(sourceBuffer),
            backHeight: backImage?.height ?? CVPixelBufferGetHeight(sourceBuffer),
            outputWidth: width, outputHeight: height,
            hasBack: backImage != nil, showCalibration: showCalibration
        )
        do {
            if let target = renderer.texture(from: buffer) {
                try renderer.render(source: sourceTexture, back: backTexture, uniforms: uniforms, into: target, wait: true)
            } else {
                let image = try renderer.renderReadback(
                    source: sourceTexture, back: backTexture, uniforms: uniforms, width: width, height: height
                )
                writeBGRA(image, into: buffer)
            }
        } catch {
            return nil
        }
        return buffer
    }

    static func preparedAudioInput(asset: AVAsset) async throws -> AVAssetWriterInput? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let formats = try await track.load(.formatDescriptions)
        // Nil output settings copy the source track as-is, including AAC 48 kHz stereo.
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        return input
    }

    static func appendAudio(from asset: AVAsset, range: CMTimeRange, to input: AVAssetWriterInput) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            input.markAsFinished()
            return
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            input.markAsFinished()
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            input.markAsFinished()
            return
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let shifted = shiftedTiming(sample, by: range.start) else { continue }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            if !input.append(shifted) { break }
        }
        input.markAsFinished()
    }

    static func finish(_ writer: AVAssetWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportFailure.writer(writer.error?.localizedDescription ?? "The encoder failed"))
                }
            }
        }
    }

    static func exportSession(_ session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ExportFailure.writer(session.error?.localizedDescription ?? "Export failed"))
                }
            }
        }
    }

    static func orientedSize(_ natural: CGSize, _ transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        if size.width < 2 || size.height < 2 { return natural }
        return size
    }

    static var bgraSettings: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    static func pixelAttributes(width: Int, height: Int) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
    }

    static func videoSettings(codec: VideoCodec, width: Int, height: Int, bitrate: Int, fps: Double) -> [String: Any] {
        [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
        ]
    }

    static func aacSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
    }

    static func pcmSampleBuffer(samples: [Int16], sampleRate: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil as UnsafePointer<AudioChannelLayout>?,
            magicCookieSize: 0,
            magicCookie: nil as UnsafeRawPointer?,
            extensions: nil as CFDictionary?,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        let frames = samples.count
        let bytes = frames * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil as UnsafeMutableRawPointer?,
            blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil as UnsafePointer<CMBlockBufferCustomBlockSource>?,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Int32(sampleRate.rounded()))),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil as CMSampleBufferMakeDataReadyCallback?,
            refcon: nil as UnsafeMutableRawPointer?,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil as UnsafePointer<Int>?,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    static func shiftedTiming(_ sample: CMSampleBuffer, by start: CMTime) -> CMSampleBuffer? {
        var needed: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: 0,
            arrayToFill: nil as UnsafeMutablePointer<CMSampleTimingInfo>?,
            entriesNeededOut: &needed
        )
        let count = max(1, needed)
        var timing = Array(
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: count
        )
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &needed)
        for index in 0..<timing.count {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, start)
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, start)
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
#endif
