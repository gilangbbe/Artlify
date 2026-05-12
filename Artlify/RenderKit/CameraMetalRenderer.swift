//
//  CameraMetalRenderer.swift
//  Artlify / RenderKit
//
//  MTKView delegate. As of M3 it can run in two modes:
//
//   * Passthrough (default) — blits the latest camera CVPixelBuffer.
//   * Composite — every draw it samples the camera + the two most
//     recent stylized textures (aiPrev, aiNext) + the optional person
//     mask, blends them per CompositeUniforms (temporal blend t over
//     the last stylized cycle), and writes one full-screen quad.
//
//  All texture submission is non-blocking. Producers (capture,
//  diffusion, vision) call `submit*` whenever they have new data;
//  the renderer never waits on them and always draws with whatever it
//  has. This is the latest-frame-wins discipline from
//  ProjectDocument.md §4 / §7.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import CoreGraphics
import OSLog

public final class CameraMetalRenderer: NSObject, MTKViewDelegate {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "Renderer")

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let passthroughPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    // Live inputs.
    private var latestCameraTexture: MTLTexture?
    private var aiPrev: MTLTexture?
    private var aiNext: MTLTexture?
    private var aiNextSubmittedAt: CFAbsoluteTime = 0
    /// Estimated cycle length of the diffusion pipeline, in seconds.
    /// Used to drive the prev→next blend `t`. Updated on every stylized
    /// submit using the inter-arrival interval (EMA, alpha=0.3).
    private var styleCycleSeconds: Double = 1.0
    private var lastStyleArrival: CFAbsoluteTime = 0

    private var personMaskTexture: MTLTexture?

    /// Public composite knobs. Read on the main thread (draw callback).
    public var compositeEnabled: Bool = false
    public var styleStrength: Float = 1.0
    public var maskEnabled: Bool = true
    public var maskSoftness: Float = 1.0

    public private(set) var drawnFrames: Int = 0
    public private(set) var droppedFrames: Int = 0
    private var lastFPSReport = CFAbsoluteTimeGetCurrent()

    public init(device: MTLDevice = MTLCreateSystemDefaultDevice()!) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = queue

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard
            let vfn = library.makeFunction(name: "passthrough_vertex"),
            let pfn = library.makeFunction(name: "passthrough_fragment"),
            let cfn = library.makeFunction(name: "composite_fragment")
        else {
            throw RendererError.shaderNotFound
        }

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = vfn
        pdesc.fragmentFunction = pfn
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.passthroughPipeline = try device.makeRenderPipelineState(descriptor: pdesc)

        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.vertexFunction = vfn
        cdesc.fragmentFunction = cfn
        cdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.compositePipeline = try device.makeRenderPipelineState(descriptor: cdesc)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw RendererError.textureCacheCreationFailed
        }
        self.textureCache = cache

        super.init()
    }

    // MARK: - Submit (camera)

    /// Push a new camera frame. Replaces any pending frame.
    public func submit(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTex
        )
        guard status == kCVReturnSuccess,
              let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex)
        else {
            droppedFrames += 1
            return
        }
        latestCameraTexture = tex
    }

    // MARK: - Submit (mask)

    /// Push a new person-segmentation mask (single-channel R8). May be nil
    /// to clear. Cheap; called from VisionSession at ~15 Hz.
    public func submitMask(_ pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer, let cache = textureCache else {
            personMaskTexture = nil
            return
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &cvTex
        )
        guard status == kCVReturnSuccess,
              let cvTex,
              let tex = CVMetalTextureGetTexture(cvTex)
        else { return }
        personMaskTexture = tex
    }

    // MARK: - Submit (stylized)

    /// Push a new stylized CGImage. Promotes the previous "next" to "prev"
    /// so the temporal blend can fade between them.
    public func submitStylized(_ cgImage: CGImage) {
        guard let texture = makeTexture(from: cgImage) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if lastStyleArrival > 0 {
            let interval = now - lastStyleArrival
            // Clamp wild outliers; smooth with EMA alpha=0.3.
            let bounded = min(max(interval, 0.05), 5.0)
            styleCycleSeconds = 0.7 * styleCycleSeconds + 0.3 * bounded
        }
        lastStyleArrival = now

        // If we already had a "next", it becomes "prev"; otherwise both
        // slots get the same texture so the first arrival doesn't pop.
        if let existingNext = aiNext {
            aiPrev = existingNext
        } else {
            aiPrev = texture
        }
        aiNext = texture
        aiNextSubmittedAt = now
    }

    public func clearStylized() {
        aiPrev = nil
        aiNext = nil
        lastStyleArrival = 0
    }

    private func makeTexture(from cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        defer { raw.deallocate() }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: raw, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: raw,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    public func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let cmd = commandQueue.makeCommandBuffer(),
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        if compositeEnabled, let cam = latestCameraTexture, let next = aiNext {
            let prev = aiPrev ?? next
            // Blend t = how far we are into the most recent style cycle.
            let elapsed = CFAbsoluteTimeGetCurrent() - aiNextSubmittedAt
            let t = Float(min(1.0, max(0.0, elapsed / max(0.05, styleCycleSeconds))))

            var uniforms = CompositeUniforms(
                blend_t: t,
                style_strength: styleStrength,
                mask_enabled: (maskEnabled && personMaskTexture != nil) ? 1.0 : 0.0,
                mask_softness: maskSoftness
            )

            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(cam, index: 0)
            enc.setFragmentTexture(prev, index: 1)
            enc.setFragmentTexture(next, index: 2)
            enc.setFragmentTexture(personMaskTexture ?? cam, index: 3)
            enc.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<CompositeUniforms>.stride,
                                 index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawnFrames += 1
        } else if let cam = latestCameraTexture {
            enc.setRenderPipelineState(passthroughPipeline)
            enc.setFragmentTexture(cam, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawnFrames += 1
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFPSReport >= 1.0 {
            let fps = Double(drawnFrames) / (now - lastFPSReport)
            log.debug("Render FPS: \(fps, format: .fixed(precision: 1)) (dropped: \(self.droppedFrames))")
            drawnFrames = 0
            droppedFrames = 0
            lastFPSReport = now
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

/// Must match the layout of the Metal `CompositeUniforms` struct.
private struct CompositeUniforms {
    var blend_t: Float
    var style_strength: Float
    var mask_enabled: Float
    var mask_softness: Float
}

public enum RendererError: Error, LocalizedError {
    case commandQueueUnavailable
    case shaderNotFound
    case textureCacheCreationFailed

    public var errorDescription: String? {
        switch self {
        case .commandQueueUnavailable: return "Could not create a Metal command queue."
        case .shaderNotFound: return "Required Metal shader functions are missing from the default library."
        case .textureCacheCreationFailed: return "Could not create a CVMetalTextureCache."
        }
    }
}
