//
//  ParticleField.swift
//  Artlify / ParticleKit
//
//  Owns the per-installation particle simulation: the GPU buffer, the
//  Metal compute + render pipeline states, and the user-facing knobs.
//
//  The renderer (CameraMetalRenderer) calls `advance(...)` once per
//  frame on its command buffer, then `encodeRender(...)` inside the
//  drawable's render pass. This keeps the renderer the single owner
//  of the command queue and present.
//
//  All knobs are @Observable so SwiftUI sliders can drive them without
//  any explicit re-binding.
//

import Foundation
import Metal
import MetalKit
import Observation
import simd
import OSLog

/// Per-particle state. **Layout MUST match `GPUParticle` in Particles.metal.**
/// 8 floats × 4 bytes = 32 bytes, naturally 16-byte aligned.
struct GPUParticle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var home:     SIMD2<Float>
    var seed:     Float
    var life:     Float
}

/// Per-frame uniforms. **Layout MUST match `ParticleUniforms` in Particles.metal.**
struct ParticleUniforms {
    var dt:         Float
    var time:       Float
    var attraction: Float
    var damping:    Float
    var flow:       Float
    var flowScale:  Float
    var maskGate:   Float
    var pointSize:  Float
    var glow:       Float
    var hueShift:   Float
    var viewport:   SIMD2<Float>

    var audioLevel:    Float
    var audioLow:      Float
    var audioMid:      Float
    var audioHigh:     Float
    var audioPan:      Float
    var audioTransient:Float
    var audioStrength: Float
}

@MainActor
@Observable
public final class ParticleField {

    private let log = Logger(subsystem: "com.biru.Artlify", category: "ParticleKit")

    // ---- User knobs (read once per frame inside CameraMetalRenderer.draw)
    public var enabled: Bool      = true
    /// Pull strength toward the silhouette gradient (into the body).
    public var attraction: Float  = 1.6
    /// Velocity damping each step. Closer to 1 = longer trails.
    public var damping: Float     = 0.92
    /// Curl-noise flow magnitude — the "fluid" feel.
    public var flow: Float        = 0.45
    /// Spatial frequency of the curl noise. Higher = tighter swirls.
    public var flowScale: Float   = 6.0
    /// 0 = particles visible everywhere, 1 = only inside silhouette.
    public var maskGate: Float    = 1.0
    /// Sprite size in pixels.
    public var pointSize: Float   = 5.0
    /// Overall brightness multiplier (additive).
    public var glow: Float        = 1.0
    /// Base hue (0..1). 0.55 ≈ cyan, 0.78 ≈ magenta, 0.13 ≈ amber.
    public var hueShift: Float    = 0.55

    // ---- Audio reactivity
    /// Optional reactor whose latest snapshot is read once per frame.
    /// When nil or `audioStrength == 0`, audio modulation is a no-op.
    public var audioReactor: AudioReactor?
    /// 0 = ignore audio, 1 = full modulation.
    public var audioStrength: Float = 0.0

    /// Number of live particles. Changing this rebuilds the buffer.
    public var count: Int = 30_000 {
        didSet {
            if oldValue != count {
                rebuildBuffer()
            }
        }
    }

    // ---- GPU resources
    public let device: MTLDevice
    private(set) var particleBuffer: MTLBuffer
    private(set) var computePipeline: MTLComputePipelineState
    private(set) var renderPipeline: MTLRenderPipelineState

    private var lastUpdate: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    public init(device: MTLDevice) throws {
        self.device = device

        let library = try device.makeDefaultLibrary(bundle: .main)
        guard
            let updateFn = library.makeFunction(name: "update_particles"),
            let vertexFn = library.makeFunction(name: "particle_vertex"),
            let fragFn   = library.makeFunction(name: "particle_fragment")
        else {
            throw ParticleError.shaderNotFound
        }

        self.computePipeline = try device.makeComputePipelineState(function: updateFn)

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction   = vertexFn
        pdesc.fragmentFunction = fragFn
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Additive blending so dots glow when they pile up. Premultiplied
        // alpha is computed in the fragment shader.
        let ca = pdesc.colorAttachments[0]!
        ca.isBlendingEnabled             = true
        ca.rgbBlendOperation             = .add
        ca.alphaBlendOperation           = .add
        ca.sourceRGBBlendFactor          = .one
        ca.sourceAlphaBlendFactor        = .one
        ca.destinationRGBBlendFactor     = .one
        ca.destinationAlphaBlendFactor   = .one

        self.renderPipeline = try device.makeRenderPipelineState(descriptor: pdesc)

        // Allocate buffer for the initial count and seed it.
        let length = MemoryLayout<GPUParticle>.stride * 30_000
        guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw ParticleError.bufferAllocationFailed
        }
        self.particleBuffer = buf
        Self.seed(buffer: buf, count: 30_000)
    }

    // ---- Buffer management

    private func rebuildBuffer() {
        let n = max(1_000, min(count, 200_000))
        let length = MemoryLayout<GPUParticle>.stride * n
        guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
            log.error("Failed to allocate particle buffer for n=\(n)")
            return
        }
        Self.seed(buffer: buf, count: n)
        self.particleBuffer = buf
        log.debug("Rebuilt particle buffer for \(n) particles")
    }

    /// Seed each particle on a jittered grid in [0,1]² with home == position.
    private static func seed(buffer: MTLBuffer, count: Int) {
        let ptr = buffer.contents().bindMemory(to: GPUParticle.self, capacity: count)
        let cols = max(1, Int(ceil(sqrt(Double(count)))))
        for i in 0..<count {
            let cx = Float(i % cols)
            let cy = Float(i / cols)
            let nx = (cx + Float.random(in: 0...1)) / Float(cols)
            let ny = (cy + Float.random(in: 0...1)) / Float(cols)
            let home = SIMD2<Float>(min(0.999, max(0.001, nx)),
                                    min(0.999, max(0.001, ny)))
            ptr[i] = GPUParticle(
                position: home,
                velocity: .zero,
                home:     home,
                seed:     Float.random(in: 0...1),
                life:     Float.random(in: 0.3...1.0)
            )
        }
    }

    // ---- Per-frame entry points called by CameraMetalRenderer

    /// Encode a compute pass that advances every particle one tick.
    /// Pass the segmentation mask texture (or nil to disable repulsion).
    public func encodeUpdate(commandBuffer: MTLCommandBuffer,
                             mask: MTLTexture?,
                             viewport: SIMD2<Float>) {
        guard enabled,
              let enc = commandBuffer.makeComputeCommandEncoder()
        else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let rawDt = now - lastUpdate
        lastUpdate = now
        // Clamp dt — first frame and pause/resume can produce huge values
        // that explode the integrator.
        let dt = Float(min(max(rawDt, 1.0 / 240.0), 1.0 / 20.0))

        let audio = audioReactor?.latest ?? .zero

        var u = ParticleUniforms(
            dt:         dt,
            time:       Float(now - startTime),
            attraction: mask == nil ? 0.0 : attraction,
            damping:    damping,
            flow:       flow,
            flowScale:  flowScale,
            maskGate:   mask == nil ? 0.0 : maskGate,
            pointSize:  pointSize,
            glow:       glow,
            hueShift:   hueShift,
            viewport:   viewport,
            audioLevel:    audio.level,
            audioLow:      audio.low,
            audioMid:      audio.mid,
            audioHigh:     audio.high,
            audioPan:      audio.pan,
            audioTransient:audio.transient,
            audioStrength: audioStrength
        )

        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(particleBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.setTexture(mask, index: 0)

        let n = particleBuffer.length / MemoryLayout<GPUParticle>.stride
        let tew = computePipeline.threadExecutionWidth
        let tg  = MTLSize(width: tew, height: 1, depth: 1)
        // Round up to full threadgroups; the shader checks bounds.
        let grid = MTLSize(
            width: ((n + tew - 1) / tew) * tew,
            height: 1, depth: 1
        )
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    /// Encode the particle render pass into an existing render encoder
    /// (so we draw on top of whatever base layer was just rendered).
    /// `mask` is sampled in the vertex stage so the fragment can gate
    /// alpha by silhouette coverage.
    public func encodeRender(encoder: MTLRenderCommandEncoder,
                             mask: MTLTexture?,
                             viewport: SIMD2<Float>) {
        guard enabled else { return }

        let audio = audioReactor?.latest ?? .zero
        var u = ParticleUniforms(
            dt:         0,
            time:       Float(CFAbsoluteTimeGetCurrent() - startTime),
            attraction: attraction,
            damping:    damping,
            flow:       flow,
            flowScale:  flowScale,
            maskGate:   mask == nil ? 0.0 : maskGate,
            pointSize:  pointSize,
            glow:       glow,
            hueShift:   hueShift,
            viewport:   viewport,
            audioLevel:    audio.level,
            audioLow:      audio.low,
            audioMid:      audio.mid,
            audioHigh:     audio.high,
            audioPan:      audio.pan,
            audioTransient:audio.transient,
            audioStrength: audioStrength
        )

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        encoder.setVertexTexture(mask, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<ParticleUniforms>.stride, index: 1)

        let n = particleBuffer.length / MemoryLayout<GPUParticle>.stride
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: n)
    }

    /// Reset every particle back to its home position. Cheap; called
    /// from the HUD "Reset" button.
    public func reset() {
        let n = particleBuffer.length / MemoryLayout<GPUParticle>.stride
        Self.seed(buffer: particleBuffer, count: n)
    }
}

enum ParticleError: Error, LocalizedError {
    case shaderNotFound
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .shaderNotFound:        return "Particle shaders missing from default Metal library."
        case .bufferAllocationFailed: return "Could not allocate particle buffer."
        }
    }
}
