//
//  DepthAsciiMetalRenderer.swift
//  Artlify / AppShell — `particles` branch
//
//  Metal-backed renderer for the scene-aware ASCII depth grid
//  published by `DepthAsciiScene`. Replaces the SwiftUI Canvas
//  implementation in `DepthAsciiSceneOverlay`, which collapsed
//  under ~125k Text.resolve() calls per second at 96×54 × 24 Hz.
//
//  Strategy
//  --------
//  * Build a small monospaced glyph atlas (R8Unorm, 8 cols × 7
//    rows, 64 px per cell) at init using CoreText.
//  * Each frame, walk the 5184 cells on the CPU, decide glyph +
//    tint + size + sway using the exact same rules the Canvas
//    code used, and memcpy into a triple-buffered MTLBuffer.
//  * Issue ONE `drawPrimitives(.triangleStrip, vertexCount: 4,
//    instanceCount: 5184)` call. The vertex shader expands each
//    instance into a quad, the fragment shader samples the atlas.
//
//  ~100× fewer draws than Canvas; per-cell CPU work is unchanged
//  but now sub-millisecond because we skip text-shaping entirely.
//

import AppKit
import CoreGraphics
import CoreText
import Metal
import MetalKit
import OSLog
import SwiftUI
import simd

// MARK: - GPU types (must match DepthAsciiMetal.metal layouts)

/// 16 bytes, alignment 4. Matches `struct AsciiCell` in
/// DepthAsciiMetal.metal exactly.
private struct AsciiCellGPU {
    var glyphIndex: UInt32
    var colorRGBA: UInt32   // 0xRRGGBBAA
    var sizeScale: Float
    var swayX: Float
}

/// 32 bytes, alignment 8. Matches `struct AsciiUniforms`.
private struct AsciiUniforms {
    var viewSize: SIMD2<Float>
    var tilesXY: SIMD2<UInt32>
    var atlasGrid: SIMD2<UInt32>
    var atlasCellPx: SIMD2<Float>
}

// MARK: - Glyph atlas

/// Pre-rasterised monospaced glyph atlas. Stores one R8Unorm cell
/// per unique glyph from the near / mid / far ramps; the renderer
/// looks up `atlasIndex(for:)` per cell per frame.
private final class DepthAsciiAtlas {

    static let cellPx: Int = 64
    static let cols: Int = 8
    static let rows: Int = 7    // 56 slots; we need ≤49

    let texture: MTLTexture
    /// near[i] → atlas index for `AsciiRamps.near[i]`. Same for
    /// `mid` / `far`. Lets the per-cell hot path do a single
    /// `[Int] → UInt32` lookup instead of a dictionary probe.
    let nearIndices: [UInt32]
    let midIndices: [UInt32]
    let farIndices: [UInt32]

    init?(device: MTLDevice) {
        let w = Self.cols * Self.cellPx
        let h = Self.rows * Self.cellPx

        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background; we draw white glyphs and sample R8 in
        // the fragment shader.
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // CoreText is the only path that gives us pixel-accurate
        // glyph rendering against an arbitrary CGContext on macOS.
        // NSFont → CTFont via toll-free bridging.
        let nearFont = CTFontCreateWithName(
            "Menlo-Bold" as CFString,
            CGFloat(Self.cellPx) * 0.78, nil
        )
        let restFont = CTFontCreateWithName(
            "Menlo" as CFString,
            CGFloat(Self.cellPx) * 0.72, nil
        )

        var indexFor: [Character: Int] = [:]
        var next = 0

        @discardableResult
        func placeGlyph(_ ch: Character, font: CTFont) -> Int {
            if let existing = indexFor[ch] { return existing }
            let slot = next
            next += 1
            let col = slot % Self.cols
            let row = slot / Self.cols
            let cellOriginX = col * Self.cellPx
            // Atlas Y matches the shader's UV expectation (top-left
            // origin once we account for CG's y-up coordinate
            // system below).
            let cellOriginY = (Self.rows - 1 - row) * Self.cellPx

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(gray: 1, alpha: 1)
            ]
            let astr = NSAttributedString(string: String(ch), attributes: attrs)
            let line = CTLineCreateWithAttributedString(astr)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let tx = CGFloat(cellOriginX) + (CGFloat(Self.cellPx) - bounds.width) * 0.5 - bounds.minX
            let ty = CGFloat(cellOriginY) + (CGFloat(Self.cellPx) - bounds.height) * 0.5 - bounds.minY
            ctx.textPosition = CGPoint(x: tx, y: ty)
            CTLineDraw(line, ctx)
            indexFor[ch] = slot
            return slot
        }

        // Slot 0 is the empty cell — atlasIndex 0 with alpha 0
        // means "render nothing" for gated cells.
        _ = placeGlyph(" ", font: restFont)

        self.nearIndices = AsciiRamps.near.map { UInt32(placeGlyph($0, font: nearFont)) }
        self.midIndices  = AsciiRamps.mid.map  { UInt32(placeGlyph($0, font: restFont)) }
        self.farIndices  = AsciiRamps.far.map  { UInt32(placeGlyph($0, font: restFont)) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: w, height: h,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        guard let data = ctx.data else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: w
        )
        // Atlas was rendered with CG y-up; the shader samples with
        // top-left UV origin. We flip on upload by reading row
        // (rows - 1 - row) above when computing cellOriginY, so the
        // texture as uploaded is already top-left-correct.
        self.texture = tex
    }
}

// MARK: - Renderer

/// MTKViewDelegate driving the instanced draw. One per
/// `DepthAsciiMetalView`; lifetime tied to the SwiftUI view.
private final class DepthAsciiMetalRenderer: NSObject, MTKViewDelegate {

    // Public so the view wrapper can refresh them when SwiftUI
    // recomputes its body.
    var intensity: Double = 0.9
    var density: Double = 1.0
    var nearHue: Double = 0.08
    var farHue: Double = 0.58
    var contourBoost: Double = 1.3

    private let scene: DepthAsciiScene
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let atlas: DepthAsciiAtlas

    // Triple-buffer the cell data so the GPU and CPU don't fight
    // over the same MTLBuffer. 3 in-flight frames is the MTKView
    // default.
    private var cellBuffers: [MTLBuffer] = []
    private var bufferIndex: Int = 0
    private let inflight = DispatchSemaphore(value: 3)

    private var viewSize: SIMD2<Float> = .init(1, 1)
    private var lastSceneUpdate: CFAbsoluteTime = 0

    private let log = Logger(subsystem: "com.biru.Artlify",
                              category: "DepthAsciiMetal")

    init?(scene: DepthAsciiScene, device: MTLDevice) {
        self.scene = scene
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        self.queue = q

        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "depth_ascii_vs"),
              let ffn = library.makeFunction(name: "depth_ascii_fs") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let cad = desc.colorAttachments[0]!
        cad.pixelFormat = .bgra8Unorm
        // Standard premultiplied-source-over blend.
        cad.isBlendingEnabled = true
        cad.rgbBlendOperation = .add
        cad.alphaBlendOperation = .add
        cad.sourceRGBBlendFactor = .one
        cad.sourceAlphaBlendFactor = .one
        cad.destinationRGBBlendFactor = .oneMinusSourceAlpha
        cad.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }

        guard let atlas = DepthAsciiAtlas(device: device) else { return nil }
        self.atlas = atlas

        let n = scene.tilesX * scene.tilesY
        let bytes = n * MemoryLayout<AsciiCellGPU>.stride
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else {
                return nil
            }
            self.cellBuffers.append(b)
        }

        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = SIMD2<Float>(Float(max(1, size.width)),
                                 Float(max(1, size.height)))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer()
        else { return }

        _ = inflight.wait(timeout: .distantFuture)
        cmd.addCompletedHandler { [weak self] _ in
            self?.inflight.signal()
        }

        bufferIndex = (bufferIndex + 1) % cellBuffers.count
        let buf = cellBuffers[bufferIndex]
        updateCells(into: buf)

        // Clear to transparent so the camera underlay shows through
        // the empty cells.
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            cmd.commit()
            return
        }
        enc.setRenderPipelineState(pipeline)

        var uniforms = AsciiUniforms(
            viewSize: viewSize,
            tilesXY: SIMD2<UInt32>(UInt32(scene.tilesX), UInt32(scene.tilesY)),
            atlasGrid: SIMD2<UInt32>(UInt32(DepthAsciiAtlas.cols),
                                      UInt32(DepthAsciiAtlas.rows)),
            atlasCellPx: SIMD2<Float>(Float(DepthAsciiAtlas.cellPx),
                                       Float(DepthAsciiAtlas.cellPx))
        )
        enc.setVertexBytes(&uniforms,
                           length: MemoryLayout<AsciiUniforms>.stride,
                           index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setFragmentTexture(atlas.texture, index: 0)

        let n = scene.tilesX * scene.tilesY
        enc.drawPrimitives(type: .triangleStrip,
                           vertexStart: 0,
                           vertexCount: 4,
                           instanceCount: n)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Per-frame cell update

    /// Fills `buf` with `tilesX*tilesY` AsciiCellGPU records using
    /// the same band/colour/sway rules the SwiftUI Canvas overlay
    /// used. Pure CPU work, ~5k iterations; on M-series this is
    /// well under a millisecond.
    private func updateCells(into buf: MTLBuffer) {
        let gx = scene.tilesX, gy = scene.tilesY
        let n = gx * gy
        let depth = scene.depthGrid
        let edge  = scene.edgeGrid
        guard depth.count == n, edge.count == n else { return }

        let ptr = buf.contents().assumingMemoryBound(to: AsciiCellGPU.self)

        let tSec = CFAbsoluteTimeGetCurrent()
        let tick = Int(tSec * 6.0)

        // Pre-pack the three palette tints as 0xRRGGBBAA bases
        // (alpha filled per-cell from opacity).
        let nearRGB = hsvToRGB(h: nearHue, s: 0.55, v: 1.0)
        let farRGB  = hsvToRGB(h: farHue,  s: 0.45, v: 0.80)
        let midRGB  = hsvToRGB(h: (nearHue + farHue) * 0.5, s: 0.5, v: 0.90)
        let intensityF = Float(intensity)
        let densityF = Float(density)
        let contourBoostF = Float(contourBoost)

        // Cell pixel dims (computed from current view size — sway is
        // in pixels).
        let cellWpx = viewSize.x / Float(gx)
        // cellH unused: kept implicit via shader.

        for y in 0..<gy {
            for x in 0..<gx {
                let i = y * gx + x
                let d = depth[i]
                let e = edge[i]

                // Density gate: same formula as Canvas.
                let keepP = densityF * max(0.15, d * 1.05 + 0.10)
                let h0 = Self.stableHash(x: x, y: y, tick: 0)
                if Float(h0 & 0xFF) / 255.0 > keepP {
                    ptr[i] = AsciiCellGPU(glyphIndex: 0,
                                          colorRGBA: 0,
                                          sizeScale: 0,
                                          swayX: 0)
                    continue
                }

                var glyphIdx: UInt32 = 0
                var tintRGB: SIMD3<Float> = .zero
                var opacity: Float = 0
                if d > 0.62 {
                    let ramp = atlas.nearIndices
                    let boost = min(Float(1.0),
                                    e * contourBoostF + (d - 0.62) * 1.5)
                    let idx = max(0, min(ramp.count - 1,
                                          Int(boost * Float(ramp.count - 1))))
                    glyphIdx = ramp[idx]
                    tintRGB = nearRGB
                    opacity = 0.75 + 0.25 * d
                } else if d > 0.32 {
                    let ramp = atlas.midIndices
                    let h = Self.stableHash(x: x, y: y, tick: tick / 8)
                    let idx = Int(h % UInt32(ramp.count))
                    glyphIdx = ramp[idx]
                    tintRGB = midRGB
                    opacity = 0.40 + 0.40 * d
                } else {
                    let ramp = atlas.farIndices
                    let h = Self.stableHash(x: x, y: y, tick: tick / 4)
                    let idx = Int(h % UInt32(ramp.count))
                    glyphIdx = ramp[idx]
                    tintRGB = farRGB
                    opacity = 0.18 + 0.35 * d
                }

                // Subtle far-band horizontal sway, same coefficient
                // and seeding as the Canvas implementation.
                let sway: Float = d < 0.32
                    ? Float(sin(tSec * 0.7
                                 + Double(x) * 0.13
                                 + Double(y) * 0.09)) * cellWpx * 0.18
                    : 0

                let sizeScale: Float = 0.55 + 0.45 * d

                let alpha = max(0, min(1, opacity * intensityF))
                let r = UInt32(max(0, min(255, tintRGB.x * 255)))
                let g = UInt32(max(0, min(255, tintRGB.y * 255)))
                let b = UInt32(max(0, min(255, tintRGB.z * 255)))
                let a = UInt32(alpha * 255)
                let rgba: UInt32 = (r << 24) | (g << 16) | (b << 8) | a

                ptr[i] = AsciiCellGPU(glyphIndex: glyphIdx,
                                      colorRGBA: rgba,
                                      sizeScale: sizeScale,
                                      swayX: sway)
            }
        }
    }

    // MARK: - Helpers

    /// FNV-1a-flavoured per-cell hash — same shape as the Canvas
    /// version so the renderers stay visually congruent during the
    /// migration period.
    private static func stableHash(x: Int, y: Int, tick: Int) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for v in [UInt32(bitPattern: Int32(x)),
                  UInt32(bitPattern: Int32(y)),
                  UInt32(bitPattern: Int32(tick))] {
            h = (h ^ v) &* 0x0100_0193
        }
        return h
    }

    /// SwiftUI Color(hue:saturation:brightness:) → 0…1 RGB. Pure
    /// HSV; we don't need device-aware colour because the atlas
    /// texture is greyscale and tints are multiplicative.
    private func hsvToRGB(h: Double, s: Double, v: Double) -> SIMD3<Float> {
        let hh = (h.truncatingRemainder(dividingBy: 1.0) + 1.0)
            .truncatingRemainder(dividingBy: 1.0) * 6.0
        let c = v * s
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2.0) - 1))
        let m = v - c
        let rgb: (Double, Double, Double)
        switch Int(hh) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return SIMD3<Float>(Float(rgb.0 + m),
                             Float(rgb.1 + m),
                             Float(rgb.2 + m))
    }
}

// MARK: - SwiftUI wrapper

/// NSViewRepresentable that hosts an MTKView driving
/// `DepthAsciiMetalRenderer`. API matches the old
/// `DepthAsciiSceneOverlay` so ContentView only swaps the type
/// name.
struct DepthAsciiMetalView: NSViewRepresentable {

    let scene: DepthAsciiScene
    var intensity: Double = 0.9
    var density: Double = 1.0
    var nearHue: Double = 0.08
    var farHue: Double = 0.58
    var contourBoost: Double = 1.3

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        fileprivate var renderer: DepthAsciiMetalRenderer?
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero,
                           device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.autoResizeDrawable = true

        if let device = view.device,
           let r = DepthAsciiMetalRenderer(scene: scene, device: device) {
            r.intensity = intensity
            r.density = density
            r.nearHue = nearHue
            r.farHue = farHue
            r.contourBoost = contourBoost
            view.delegate = r
            context.coordinator.renderer = r
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        // Push the latest knob values into the live renderer. The
        // renderer reads them on the next draw tick.
        guard let r = context.coordinator.renderer else { return }
        r.intensity = intensity
        r.density = density
        r.nearHue = nearHue
        r.farHue = farHue
        r.contourBoost = contourBoost
    }
}
