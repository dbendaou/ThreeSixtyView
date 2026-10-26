import Foundation
#if os(macOS)
import Metal
import CoreVideo
import QuartzCore
import simd
import ProjectionMath

public enum MetalRenderError: Error, CustomStringConvertible {
    case noDevice
    case library(String)
    case pipeline(String)
    case texture

    public var description: String {
        switch self {
        case .noDevice: return "This Mac doesn't have a Metal device."
        case .library(let message): return "Metal shader failed to compile. \(message)"
        case .pipeline(let message): return "Metal pipeline failed. \(message)"
        case .texture: return "Couldn't upload a video frame to the GPU."
        }
    }
}

public final class MetalRenderer {
    /// sRGB drawable so video-encoded bytes round-trip instead of being treated as linear (which washes the picture out).
    public static let colorFormat: MTLPixelFormat = .bgra8Unorm_srgb

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw MetalRenderError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw MetalRenderError.pipeline("No command queue") }
        self.queue = queue
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        } catch {
            throw MetalRenderError.library(error.localizedDescription)
        }
        guard let vertex = library.makeFunction(name: "vs_main"),
              let fragment = library.makeFunction(name: "fs_main") else {
            throw MetalRenderError.library("Missing vs_main or fs_main")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.colorFormat
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw MetalRenderError.pipeline(error.localizedDescription)
        }
        var created: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &created)
        cache = created
    }

    public func texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, Self.colorFormat, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    public func upload(_ image: RGBAImage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: image.width, height: image.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var bgra = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for index in 0..<(image.width * image.height) {
            bgra[index * 4] = image.rgba[index * 4 + 2]
            bgra[index * 4 + 1] = image.rgba[index * 4 + 1]
            bgra[index * 4 + 2] = image.rgba[index * 4]
            bgra[index * 4 + 3] = 255
        }
        bgra.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: image.width * 4)
        }
        return texture
    }

    @discardableResult
    public func render(
        source: MTLTexture,
        back: MTLTexture?,
        uniforms: GPUUniforms,
        into target: MTLTexture,
        present drawable: CAMetalDrawable? = nil,
        wait: Bool,
        syncWithTransaction: Bool = false
    ) throws -> MTLCommandBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.005, green: 0.005, blue: 0.006, alpha: 1)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRenderError.pipeline("Couldn't encode a frame")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(back ?? source, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let drawable {
            if syncWithTransaction {
                command.commit()
                command.waitUntilScheduled()
                drawable.present()
            } else {
                command.present(drawable)
                command.commit()
            }
        } else {
            command.commit()
        }
        if wait { command.waitUntilCompleted() }
        return command
    }

    public func renderReadback(
        source: MTLTexture,
        back: MTLTexture?,
        uniforms: GPUUniforms,
        width: Int,
        height: Int
    ) throws -> RGBAImage {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.colorFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { throw MetalRenderError.texture }
        try render(source: source, back: back, uniforms: uniforms, into: target, wait: true)
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        bgra.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            rgba[index * 4] = bgra[index * 4 + 2]
            rgba[index * 4 + 1] = bgra[index * 4 + 1]
            rgba[index * 4 + 2] = bgra[index * 4]
            rgba[index * 4 + 3] = 255
        }
        return RGBAImage(width: width, height: height, rgba: rgba)
    }
}

public func makePixelBuffer(width: Int, height: Int, metal: Bool) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: metal,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess else { return nil }
    return buffer
}

public func writeBGRA(_ image: RGBAImage, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let destination = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<image.height {
        for x in 0..<image.width {
            let source = (y * image.width + x) * 4
            let offset = y * bytesPerRow + x * 4
            destination[offset] = image.rgba[source + 2]
            destination[offset + 1] = image.rgba[source + 1]
            destination[offset + 2] = image.rgba[source]
            destination[offset + 3] = 255
        }
    }
}

public func readRGBA(_ buffer: CVPixelBuffer) -> RGBAImage {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    var image = RGBAImage(width: width, height: height)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return image }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let source = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            image.setPixel(x, y, source[offset + 2], source[offset + 1], source[offset], 255)
        }
    }
    return image
}
#endif
