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
    private let trailDecayPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    // Trail (feedback) accumulator. Two textures, ping-ponged each
    // frame; lazily (re)allocated when the drawable size changes.
    private var accumA: MTLTexture?
    private var accumB: MTLTexture?
    private var accumSize: CGSize = .zero

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
    /// Where the AI layer is applied. Default `.background` so a
    /// "starry night" prompt repaints the room around the person while
    /// the person stays recognisable as themselves (still subtly
    /// shaded by `styleStrength` on top of camera).
    public var maskMode: MaskMode = .background
    public var maskSoftness: Float = 1.0

    /// Optional particle layer drawn additively on top of the camera /
    /// composite pass. Owned externally so the SwiftUI shell can bind
    /// sliders to its knobs without going through the renderer.
    public var particleField: ParticleField?

    /// When true, the camera/composite blit is skipped and the drawable
    /// is left at its clear color (black). Used by the `particles` branch
    /// art-installation mode where the silhouette IS the particle field
    /// and we don't want the camera image visible behind it.
    public var darkBackground: Bool = true

    /// When true, the particle layer is rendered through a feedback
    /// accumulator that decays each frame, leaving fluid motion trails.
    /// Implies `darkBackground` for the visible output (the camera blit
    /// is skipped) because mixing trails with live camera looks muddy.
    public var trailsEnabled: Bool = true
    /// 0..0.999 — per-frame multiplier of the accumulator. 0.92 = short
    /// fluid trails; 0.97 = long ribbons; 1.0 = forever (don't).
    public var trailDecay: Float = 0.93

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
            let cfn = library.makeFunction(name: "composite_fragment"),
            let tfn = library.makeFunction(name: "trail_decay_fragment")
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

        let tdesc = MTLRenderPipelineDescriptor()
        tdesc.vertexFunction = vfn
        tdesc.fragmentFunction = tfn
        tdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // No blending — trail-decay overwrites the destination.
        self.trailDecayPipeline = try device.makeRenderPipelineState(descriptor: tdesc)

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

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        ensureAccumulators(size: size)
    }

    /// (Re)allocate the trail accumulator pair to match the drawable.
    /// Cheap to call — returns immediately if size is unchanged.
    private func ensureAccumulators(size: CGSize) {
        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        if accumA != nil, Int(accumSize.width) == w, Int(accumSize.height) == h {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        accumA = device.makeTexture(descriptor: desc)
        accumB = device.makeTexture(descriptor: desc)
        accumSize = CGSize(width: w, height: h)
    }

    public func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let rpd = view.currentRenderPassDescriptor,
            let cmd = commandQueue.makeCommandBuffer()
        else { return }

        let viewport = SIMD2<Float>(Float(view.drawableSize.width),
                                    Float(view.drawableSize.height))
        ensureAccumulators(size: view.drawableSize)

        // Step 1: advance particles (compute) BEFORE any render pass so
        // the same command buffer carries both. The render passes below
        // read the buffer the compute kernel just wrote.
        if let field = particleField {
            field.encodeUpdate(commandBuffer: cmd,
                               mask: personMaskTexture,
                               viewport: viewport)
        }

        // ----- Trail-accumulator path. Implies dark background.
        if trailsEnabled,
           let field = particleField, field.enabled,
           let prev = accumA, let next = accumB {

            // Pass A: decay prev -> next.
            let decayDesc = MTLRenderPassDescriptor()
            decayDesc.colorAttachments[0].texture = next
            decayDesc.colorAttachments[0].loadAction = .clear
            decayDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            decayDesc.colorAttachments[0].storeAction = .store
            if let denc = cmd.makeRenderCommandEncoder(descriptor: decayDesc) {
                var u = TrailUniforms(decay: max(0.0, min(0.999, trailDecay)))
                denc.setRenderPipelineState(trailDecayPipeline)
                denc.setFragmentTexture(prev, index: 0)
                denc.setFragmentBytes(&u,
                                      length: MemoryLayout<TrailUniforms>.stride,
                                      index: 0)
                denc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                denc.endEncoding()
            }

            // Pass B: particles additive into next.
            let partDesc = MTLRenderPassDescriptor()
            partDesc.colorAttachments[0].texture = next
            partDesc.colorAttachments[0].loadAction = .load
            partDesc.colorAttachments[0].storeAction = .store
            if let penc = cmd.makeRenderCommandEncoder(descriptor: partDesc) {
                field.encodeRender(encoder: penc,
                                   mask: personMaskTexture,
                                   viewport: viewport)
                penc.endEncoding()
            }

            // Pass C: present next to drawable.
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(passthroughPipeline)
                enc.setFragmentTexture(next, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            drawnFrames += 1

            // Swap so the texture we just rendered into becomes "prev"
            // for next frame.
            swap(&accumA, &accumB)

            reportFPSIfNeeded()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        // ----- No-trails path (original behaviour).
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        if darkBackground {
            // Skip the camera/composite layer entirely. The render pass's
            // clear color (set on the MTKView to opaque black) gives us
            // the dark gallery background. Particles draw additively
            // below.
            drawnFrames += 1
        } else if compositeEnabled, let cam = latestCameraTexture, let next = aiNext {
            let prev = aiPrev ?? next
            // Blend t = how far we are into the most recent style cycle.
            let elapsed = CFAbsoluteTimeGetCurrent() - aiNextSubmittedAt
            let t = Float(min(1.0, max(0.0, elapsed / max(0.05, styleCycleSeconds))))

            var uniforms = CompositeUniforms(
                blend_t: t,
                style_strength: styleStrength,
                mask_mode: (maskMode == .full || personMaskTexture == nil)
                    ? 0.0
                    : (maskMode == .person ? 1.0 : 2.0),
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

        // Step 2: particles draw additively on top of whatever just landed.
        if let field = particleField {
            field.encodeRender(encoder: enc, mask: personMaskTexture, viewport: viewport)
        }

        reportFPSIfNeeded()

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func reportFPSIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFPSReport >= 1.0 {
            let fps = Double(drawnFrames) / (now - lastFPSReport)
            log.debug("Render FPS: \(fps, format: .fixed(precision: 1)) (dropped: \(self.droppedFrames))")
            drawnFrames = 0
            droppedFrames = 0
            lastFPSReport = now
        }
    }
}

/// Must match the layout of the Metal `TrailUniforms` struct in Trail.metal.
private struct TrailUniforms {
    var decay: Float
}

/// Must match the layout of the Metal `CompositeUniforms` struct.
private struct CompositeUniforms {
    var blend_t: Float
    var style_strength: Float
    var mask_mode: Float
    var mask_softness: Float
}

/// Where the stylized layer is applied relative to the person mask.
public enum MaskMode: String, CaseIterable, Identifiable, Sendable {
    case full         // No mask: stylize the whole frame.
    case person       // Stylize the person only; background stays as camera.
    case background   // Stylize the background only; person stays as camera.

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .full:       return "Full frame"
        case .person:     return "Person"
        case .background: return "Background"
        }
    }
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
