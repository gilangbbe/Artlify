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
    private let negativeBoxesPipeline: MTLRenderPipelineState
    private let asciiPipeline: MTLRenderPipelineState
    private let negFlashPipeline: MTLRenderPipelineState
    private let asciiAtlasTexture: MTLTexture?
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

    /// Random negative-camera windows that flash around body joints.
    /// Off by default; switch on from the HUD.
    public var negativeBoxesEnabled: Bool = true
    /// Per-flash peak alpha when ContentView calls `flashNegativeBox`.
    /// Stored here so the HUD slider can tune intensity globally.
    public var negativeBoxesPeak: Float = 0.85
    private var negativeBoxes: [NegativeBoxState] = []
    private let negativeBoxesBuffer: MTLBuffer
    private static let maxNegativeBoxes = 16

    /// ASCII overlay: the camera feed inside the silhouette is
    /// re-rendered as a grid of glyphs (sparse → dense by luminance).
    /// An audio-triggered ring expands outward from `asciiOrigin`,
    /// briefly densifying glyphs as it crosses them.
    public var asciiEnabled: Bool = false
    /// Glyph cell edge in pixels. Smaller = more detail, less ASCII feel.
    public var asciiCellSize: Float = 12.0
    /// Body-anchored origin for the audio shockwave ring (uv).
    public var asciiOrigin: SIMD2<Float> = SIMD2<Float>(0.5, 0.5)
    /// Glyph tint at minimum / maximum luminance. Defaults to the
    /// classic phosphor green ramp; HUD lets the user push to amber,
    /// cyan, magenta, etc.
    public var asciiColorLow:  SIMD3<Float> = SIMD3<Float>(0.45, 0.95, 0.55)
    public var asciiColorHigh: SIMD3<Float> = SIMD3<Float>(0.85, 1.00, 0.70)
    private var asciiShockBirth: CFAbsoluteTime = -1000

    /// Negative-camera full-screen flash. When `negFlashEnabled` is
    /// true, callers push a 0…1 intensity each frame via
    /// `setNegFlash(intensity:)`; the pass fades the inverted live
    /// camera over the stylised scene. Driven by the open-hand
    /// gesture from VisionKit/HandOpen.
    public var negFlashEnabled: Bool = false
    /// 0..1 current fade. Read-only; updated by `setNegFlash`.
    public private(set) var negFlashIntensity: Float = 0
    /// RGB multiplier on the inverted image. (1,1,1) = pure photo
    /// negative. Push other values to tint the flash (e.g. amber for
    /// a vintage darkroom feel). Live-tunable from the HUD.
    public var negFlashTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
    private var negFlashUniforms: NegativeFlashUniforms?

    /// Restart the ASCII shockwave ring at `origin` (uv). Idempotent;
    /// safe to call every frame — the renderer will only honour it
    /// when audio actually fires a transient (caller's decision).
    public func triggerAsciiShockwave(origin: SIMD2<Float>) {
        asciiOrigin = origin
        asciiShockBirth = CFAbsoluteTimeGetCurrent()
    }

    /// Push the latest negative-flash intensity (0…1). Clamps + caches
    /// the uniform for the next draw; passing 0 (or with the flag
    /// disabled) silences the pass.
    public func setNegFlash(intensity: Float) {
        guard negFlashEnabled else {
            negFlashUniforms = nil
            negFlashIntensity = 0
            return
        }
        let i = max(0, min(1, intensity))
        negFlashIntensity = i
        negFlashUniforms = NegativeFlashUniforms(
            intensity: i,
            _pad0: 0,
            _pad1: SIMD2<Float>(0, 0),
            tint:  negFlashTint,
            _pad2: 0
        )
    }

    /// Encode the negative-flash pass on top of the existing scene.
    /// No-op when disabled or intensity has decayed to ~0.
    private func encodeNegFlash(_ enc: MTLRenderCommandEncoder) {
        guard negFlashEnabled,
              var u = negFlashUniforms,
              u.intensity > 0.001,
              let cam = latestCameraTexture
        else { return }
        enc.setRenderPipelineState(negFlashPipeline)
        enc.setFragmentTexture(cam, index: 0)
        enc.setFragmentBytes(&u,
                             length: MemoryLayout<NegativeFlashUniforms>.stride,
                             index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

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
            let tfn = library.makeFunction(name: "trail_decay_fragment"),
            let nfn = library.makeFunction(name: "negative_boxes_fragment"),
            let afn = library.makeFunction(name: "ascii_fragment"),
            let hfn = library.makeFunction(name: "negflash_fragment")
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

        // Negative boxes pass: standard alpha blend over the drawable.
        let ndesc = MTLRenderPipelineDescriptor()
        ndesc.vertexFunction = vfn
        ndesc.fragmentFunction = nfn
        ndesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        if let nca = ndesc.colorAttachments[0] {
            nca.isBlendingEnabled = true
            nca.rgbBlendOperation = .add
            nca.alphaBlendOperation = .add
            nca.sourceRGBBlendFactor = .sourceAlpha
            nca.sourceAlphaBlendFactor = .one
            nca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            nca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        self.negativeBoxesPipeline = try device.makeRenderPipelineState(descriptor: ndesc)

        // Persistent buffer for the box uniforms (32 bytes each).
        let bytes = MemoryLayout<GPUNegBox>.stride * Self.maxNegativeBoxes
        guard let nb = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw RendererError.textureCacheCreationFailed
        }
        self.negativeBoxesBuffer = nb

        // ASCII pipeline: standard alpha blend over the drawable.
        let adesc = MTLRenderPipelineDescriptor()
        adesc.vertexFunction = vfn
        adesc.fragmentFunction = afn
        adesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        if let aca = adesc.colorAttachments[0] {
            aca.isBlendingEnabled = true
            aca.rgbBlendOperation = .add
            aca.alphaBlendOperation = .add
            aca.sourceRGBBlendFactor = .one          // premultiplied in shader
            aca.sourceAlphaBlendFactor = .one
            aca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            aca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        self.asciiPipeline = try device.makeRenderPipelineState(descriptor: adesc)
        self.asciiAtlasTexture = AsciiAtlas.makeTexture(device: device)

        // Hand-frame pass: standard alpha blend over the drawable.
        // The shader writes premultiplied colour for both the camera
        // window (alpha = intensity) and the corner brackets so the
        // fade-in/fade-out reads cleanly against the scene below.
        let hdesc = MTLRenderPipelineDescriptor()
        hdesc.vertexFunction = vfn
        hdesc.fragmentFunction = hfn
        hdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        if let hca = hdesc.colorAttachments[0] {
            hca.isBlendingEnabled = true
            hca.rgbBlendOperation = .add
            hca.alphaBlendOperation = .add
            hca.sourceRGBBlendFactor = .one
            hca.sourceAlphaBlendFactor = .one
            hca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            hca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        self.negFlashPipeline = try device.makeRenderPipelineState(descriptor: hdesc)

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
        // Evict stale cache entries so their backing IOSurfaces can
        // return to the camera's pool. Without this, CMIO eventually
        // logs `ReceivedSampleBuffer N queue full` because the camera
        // daemon runs out of pool slots to write the next frame into.
        // The entry we just created stays live (referenced by `tex`).
        CVMetalTextureCacheFlush(cache, 0)
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
        // Same pool-recycling rationale as `submit(_:)` above — mask
        // frames also come from a CV-backed pool (Vision's segmentation
        // output) and benefit from per-submit cache eviction.
        CVMetalTextureCacheFlush(cache, 0)
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

    // MARK: - Submit (negative-camera box flashes)

    /// Trigger a single flashing negative-camera window centered at
    /// `center` (uv, top-left origin) with `halfSize` extents (uv).
    /// Alpha rises and falls over `duration` seconds, peaking at the
    /// midpoint. Boxes silently drop after they expire; the renderer
    /// caps live boxes at MAX_NEG_BOXES (oldest are evicted).
    public func flashNegativeBox(center: SIMD2<Float>,
                                 halfSize: SIMD2<Float>,
                                 duration: TimeInterval = 0.45,
                                 peak: Float? = nil) {
        let now = CFAbsoluteTimeGetCurrent()
        let p = peak ?? negativeBoxesPeak
        let box = NegativeBoxState(center: center,
                                   halfSize: halfSize,
                                   birth: now,
                                   duration: max(0.05, duration),
                                   peak: max(0, min(1, p)))
        negativeBoxes.append(box)
        if negativeBoxes.count > Self.maxNegativeBoxes {
            // Drop oldest first.
            negativeBoxes.removeFirst(negativeBoxes.count - Self.maxNegativeBoxes)
        }
    }

    public func clearNegativeBoxes() {
        negativeBoxes.removeAll(keepingCapacity: true)
    }

    /// Cull expired boxes and pack the live ones into the GPU buffer.
    /// Returns the count actually written.
    private func packNegativeBoxes(now: CFAbsoluteTime) -> Int {
        // Drop expired.
        negativeBoxes.removeAll { (now - $0.birth) >= $0.duration }
        let n = min(negativeBoxes.count, Self.maxNegativeBoxes)
        guard n > 0 else { return 0 }
        let ptr = negativeBoxesBuffer.contents()
            .bindMemory(to: GPUNegBox.self, capacity: Self.maxNegativeBoxes)
        for i in 0..<n {
            let b = negativeBoxes[i]
            // Triangular envelope: rises to `peak` at duration/2, falls back.
            let t = Float((now - b.birth) / b.duration)
            let env = 1.0 - abs(2.0 * t - 1.0)         // 0..1..0
            let alpha = b.peak * max(0, min(1, env))
            ptr[i] = GPUNegBox(
                rect: SIMD4<Float>(b.center.x, b.center.y,
                                   b.halfSize.x, b.halfSize.y),
                props: SIMD4<Float>(alpha, 0, 0, 0)
            )
        }
        return n
    }

    /// Encode the negative-boxes pass on top of an existing render
    /// encoder targeting the drawable. No-op if disabled, no boxes,
    /// or no camera texture is available.
    private func encodeNegativeBoxes(_ enc: MTLRenderCommandEncoder,
                                     count: Int) {
        guard count > 0,
              negativeBoxesEnabled,
              let cam = latestCameraTexture
        else { return }
        enc.setRenderPipelineState(negativeBoxesPipeline)
        enc.setFragmentTexture(cam, index: 0)
        enc.setFragmentBuffer(negativeBoxesBuffer, offset: 0, index: 1)
        var c = Int32(count)
        enc.setFragmentBytes(&c, length: MemoryLayout<Int32>.size, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Encode the ASCII overlay pass. No-op if disabled, no camera or
    /// mask, or atlas allocation failed at init.
    private func encodeAscii(_ enc: MTLRenderCommandEncoder,
                             viewport: SIMD2<Float>,
                             audio: AudioFrame,
                             audioStrength: Float) {
        guard asciiEnabled,
              let cam = latestCameraTexture,
              let mask = personMaskTexture,
              let atlas = asciiAtlasTexture
        else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let age = now - asciiShockBirth
        // Cap visible lifetime; <0 in shader = no ring.
        let shockAge: Float = (age >= 0 && age < 2.5) ? Float(age) : -1.0

        var u = AsciiUniforms(
            viewport:       viewport,
            cellSize:       max(2.0, asciiCellSize),
            glyphCount:     Float(AsciiAtlas.glyphs.count),
            audioStrength:  audioStrength,
            audioLevel:     audio.level,
            audioLow:       audio.low,
            audioTransient: audio.transient,
            shockOrigin:    asciiOrigin,
            shockAge:       shockAge,
            shockSpeed:     0.55,
            shockWidth:     0.045,
            shockPeak:      0.85,
            colorLow:       SIMD4<Float>(asciiColorLow.x,  asciiColorLow.y,  asciiColorLow.z,  0),
            colorHigh:      SIMD4<Float>(asciiColorHigh.x, asciiColorHigh.y, asciiColorHigh.z, 0)
        )

        enc.setRenderPipelineState(asciiPipeline)
        enc.setFragmentTexture(cam,   index: 0)
        enc.setFragmentTexture(mask,  index: 1)
        enc.setFragmentTexture(atlas, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<AsciiUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
                // Pass D (same encoder): negative-camera boxes flash on top.
                let nbCount = packNegativeBoxes(now: CFAbsoluteTimeGetCurrent())
                encodeNegativeBoxes(enc, count: nbCount)
                // Pass E: ASCII overlay (uses field's audio reactor).
                let ad = particleField?.audioReactor?.latest ?? .zero
                let aStrength = particleField?.audioStrength ?? 0
                encodeAscii(enc, viewport: viewport, audio: ad, audioStrength: aStrength)
                // Pass F: negative-camera flash on top — also needed
                // here because the trails path uses a separate encoder
                // from the no-trails path below.
                encodeNegFlash(enc)
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

        // Step 3: negative-camera boxes flash on top of everything else.
        let nbCount = packNegativeBoxes(now: CFAbsoluteTimeGetCurrent())
        encodeNegativeBoxes(enc, count: nbCount)

        // Step 4: ASCII overlay (also on top — reads camera + mask).
        let ad = particleField?.audioReactor?.latest ?? .zero
        let aStrength = particleField?.audioStrength ?? 0
        encodeAscii(enc, viewport: viewport, audio: ad, audioStrength: aStrength)

        // Step 5: hand-frame viewfinder — punches a camera-content
        // window through whatever the previous steps drew. Drawn
        // last so it always reads on top.
        encodeNegFlash(enc)

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

/// Live negative-camera flash. Stored CPU-side; converted to a packed
/// `GPUNegBox` each draw via `packNegativeBoxes(now:)`.
private struct NegativeBoxState {
    var center:   SIMD2<Float>
    var halfSize: SIMD2<Float>
    var birth:    CFAbsoluteTime
    var duration: CFAbsoluteTime
    var peak:     Float
}

/// Must match the layout of the Metal `NegBox` struct in NegativeBoxes.metal.
/// 32 bytes, 16-byte aligned.
private struct GPUNegBox {
    var rect:  SIMD4<Float>   // cx, cy, hw, hh
    var props: SIMD4<Float>   // alpha, _, _, _
}

/// Must match the layout of the Metal `AsciiUniforms` struct in Ascii.metal.
private struct AsciiUniforms {
    var viewport:       SIMD2<Float>
    var cellSize:       Float
    var glyphCount:     Float
    var audioStrength:  Float
    var audioLevel:     Float
    var audioLow:       Float
    var audioTransient: Float
    var shockOrigin:    SIMD2<Float>
    var shockAge:       Float
    var shockSpeed:     Float
    var shockWidth:     Float
    var shockPeak:      Float
    // float3 in Metal is 16-byte aligned. We reflect that with a
    // padded SIMD4 on the Swift side; the shader reads .xyz.
    var colorLow:       SIMD4<Float>
    var colorHigh:      SIMD4<Float>
}

/// Must match the layout of the Metal `CompositeUniforms` struct.
private struct CompositeUniforms {
    var blend_t: Float
    var style_strength: Float
    var mask_mode: Float
    var mask_softness: Float
}

/// Must match the layout of the Metal `NegativeFlashUniforms`
/// struct in NegativeFlash.metal. Padded to 32 bytes so the
/// `float3 tint` lands on its 16-byte boundary on every GPU.
private struct NegativeFlashUniforms {
    var intensity: Float    // 0..1 fade envelope
    var _pad0:     Float
    var _pad1:     SIMD2<Float>
    var tint:      SIMD3<Float>   // RGB multiplier on the inverted image
    var _pad2:     Float
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
