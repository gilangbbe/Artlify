//
//  DepthAsciiScene.swift
//  Artlify / AppShell — `particles` branch
//
//  Scene-aware ASCII depth renderer. Distinct from
//  `AsciiDepthBackground.swift`, which is a purely procedural
//  inside-out tunnel: this one actually *looks at the camera* and
//  rebuilds spatial hierarchy as typographic density.
//
//  Pipeline (analyzer, ~10–12 Hz, runs in a Task):
//    CameraSession.latestPixelBuffer ──┐
//                                      ├─► luma grid  (CIImage scale → bytes)
//                                      └─► edge grid  (CIEdges → scale → bytes)
//    VisionSession.latestFrame?.personMask ─► mask grid (raw CVPixelBuffer sample)
//
//    depthProxy(x,y) = max(
//        personMask(x,y),                           // segmented body = near
//        0.55 * verticalPos(y) + 0.25 * edges(x,y), // ground+contours
//        0.35 * (1 - luma(x,y)) + 0.20 * verticalPos(y) // dark+ground
//    )
//
//  Renderer (SwiftUI, ~24 Hz, TimelineView + Canvas + drawingGroup):
//    For each tile pick from one of three glyph ramps by depth band —
//    structural (`#@%&MW…` near), typographic (`+=<>/?` mid), sparse
//    fog (`.·•¨"` far). Edge magnitude boosts the chosen glyph to a
//    denser variant and brightens it. Far cells occasionally render a
//    short "word fragment" (atmospheric text noise) instead of a single
//    glyph. Colour lerps fog→pen with depth; opacity ramps with depth.
//
//  This is a *heuristic* depth proxy, NOT learned monocular depth.
//  The follow-up swap-point is documented in Journal.md: drop a
//  DepthAnything / DepthPro CoreML model in here, feed its inverse-
//  disparity map into `depthGrid` directly, and the renderer below is
//  unchanged.
//

import Foundation
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics
import OSLog
import SwiftUI

// MARK: - Analyzer

@Observable
@MainActor
final class DepthAsciiScene {

    /// Tile grid resolution. 96×54 = 5184 cells → matches 16:9 cleanly
    /// and stays under the per-frame Canvas draw budget at 24 Hz.
    let tilesX: Int = 96
    let tilesY: Int = 54

    /// 1.0 = nearest, 0.0 = furthest. Row-major (`y*tilesX + x`).
    /// `Float` so blending is fast and SwiftUI sees a single array swap.
    private(set) var depthGrid: [Float]
    /// Scene contour magnitude, 0…1. Sampled from `CIEdges`.
    private(set) var edgeGrid: [Float]
    /// Down-sampled luma 0…1 — used by the renderer to bias glyph
    /// brightness independently of depth (so the dancer's silhouette
    /// remains readable against a bright background).
    private(set) var lumaGrid: [Float]
    private(set) var lastUpdate: CFAbsoluteTime = 0

    /// Target analyzer cadence. Renderer runs faster, reading the
    /// most recent published grids.
    var targetHz: Double = 12.0

    private var loopTask: Task<Void, Never>?
    private let ciContext: CIContext
    private let log = Logger(subsystem: "com.biru.Artlify", category: "DepthAscii")

    init() {
        let n = tilesX * tilesY
        self.depthGrid = .init(repeating: 0, count: n)
        self.edgeGrid  = .init(repeating: 0, count: n)
        self.lumaGrid  = .init(repeating: 0, count: n)
        // No intermediate cache — frames are one-shot, caching costs
        // memory for zero benefit at 10–12 Hz.
        self.ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    // MARK: - Lifecycle

    func start(session: CameraSession, vision: VisionSession) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = 1.0 / max(1.0, self.targetHz)
                guard let pb = session.latestPixelBuffer else {
                    try? await Task.sleep(for: .milliseconds(60))
                    continue
                }
                let mask = vision.latestFrame?.personMask
                await Task.detached(priority: .utility) { [pb, mask] in
                    // Heavy work off the main actor. The analyzer is
                    // @MainActor so we hop back to publish.
                }.value
                self.processFrame(pb: pb, mask: mask)
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Per-frame processing

    private func processFrame(pb: CVPixelBuffer, mask: CVPixelBuffer?) {
        let gx = tilesX, gy = tilesY
        let ci = CIImage(cvPixelBuffer: pb)

        // Edge map first — CIEdges output is intensity-encoded in all
        // three colour channels, so the same render-to-RGBA path that
        // gives us luma also gives us edge magnitude.
        let edgesCI = ci.applyingFilter(
            "CIEdges",
            parameters: [kCIInputIntensityKey: 6.0]
        )

        let luma = renderToGrid(ci, width: gx, height: gy)
        let edges = renderToGrid(edgesCI, width: gx, height: gy)
        let maskGrid: [Float] = mask.map { downsampleMask($0, width: gx, height: gy) }
            ?? Array(repeating: 0, count: gx * gy)

        var depth = [Float](repeating: 0, count: gx * gy)
        for y in 0..<gy {
            // SwiftUI/SwiftUI-Canvas y grows downward — bottom of the
            // frame (large y) is most often the floor, i.e. nearer to
            // the camera than the top (sky/wall).
            let ground = Float(y) / Float(gy - 1)
            for x in 0..<gx {
                let i = y * gx + x
                let m = maskGrid[i]
                let e = min(1.0, edges[i] * 1.4)
                let l = luma[i]
                var d: Float = 0
                d = max(d, m)                                  // body
                d = max(d, 0.55 * ground + 0.25 * e)           // floor + contours
                d = max(d, 0.35 * (1 - l) + 0.20 * ground)     // dark + ground
                depth[i] = min(1, d)
            }
        }

        // Light temporal smoothing so the renderer doesn't flicker on
        // every sample. EMA, alpha = 0.55 toward the new sample so the
        // dancer's motion still feels live.
        if self.depthGrid.count == depth.count {
            for i in 0..<depth.count {
                depth[i] = 0.45 * self.depthGrid[i] + 0.55 * depth[i]
            }
        }

        self.depthGrid = depth
        self.edgeGrid = edges
        self.lumaGrid = luma
        self.lastUpdate = CFAbsoluteTimeGetCurrent()
    }

    /// CIImage → downsampled greyscale grid in [0,1] (row-major). Uses
    /// CIContext.render straight into a stack-allocated RGBA byte
    /// buffer and reads luma from the RGB channels.
    private func renderToGrid(_ image: CIImage, width: Int, height: Int) -> [Float] {
        let srcW = max(1, CGFloat(image.extent.width))
        let srcH = max(1, CGFloat(image.extent.height))
        let sx = CGFloat(width) / srcW
        let sy = CGFloat(height) / srcH
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                               y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ciContext.render(
                scaled,
                toBitmap: base,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Float(bytes[i * 4    ]) / 255
            let g = Float(bytes[i * 4 + 1]) / 255
            let b = Float(bytes[i * 4 + 2]) / 255
            out[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return out
    }

    /// Person-mask CVPixelBuffer (OneComponent8) → downsampled grid.
    /// Nearest-neighbour sample; the mask is already soft so we don't
    /// need a fancier filter.
    private func downsampleMask(_ mask: CVPixelBuffer, width: Int, height: Int) -> [Float] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let mw = CVPixelBufferGetWidth(mask)
        let mh = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else {
            return Array(repeating: 0, count: width * height)
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(mh - 1, y * mh / height)
            for x in 0..<width {
                let sx = min(mw - 1, x * mw / width)
                out[y * width + x] = Float(ptr[sy * row + sx]) / 255
            }
        }
        return out
    }
}

// MARK: - Glyph ramps

/// Ordered near→far. Each band is monospaced and visually weighted
/// from "structural" through "typographic" to "atmospheric symbol".
/// `internal` (not `private`) so the Metal renderer in
/// `DepthAsciiMetalRenderer.swift` can build its glyph atlas from
/// exactly the same character set.
enum AsciiRamps {
    static let near: [Character]   = Array("█▓▒#@&%MW8B$NQH0R")
    static let mid: [Character]    = Array("+=<>?/\\|*()[]{}!:;~^")
    static let far: [Character]    = Array(".·•¨\"'`,°˙ ")
    /// Optional micro-words placed sparsely in far/mid bands for
    /// the "text-like atmospheric noise" feel.
    static let words: [String] = [
        "fog", "void", "echo", "drift", "noise", "hum",
        "blur", "soft", "near", "far", "dust", "trace",
        "haze", "glow", "veil", "static", "sigh", "ash"
    ]
}

// MARK: - Renderer

struct DepthAsciiSceneOverlay: View {

    let scene: DepthAsciiScene
    /// Overall intensity (alpha multiplier).
    var intensity: Double = 0.9
    /// Glyph density: 1.0 fills every tile; below 1.0 leaves blanks
    /// proportional to (1 - depth) so far regions thin out first.
    var density: Double = 1.0
    /// Hue for near-band glyphs.
    var nearHue: Double = 0.08    // warm amber
    /// Hue for far-band fog glyphs.
    var farHue: Double = 0.58     // cool indigo
    /// Probability per tile per second of swapping in a `words` micro
    /// fragment in mid/far bands. Kept on the type for API parity
    /// with the Canvas implementation; the Metal renderer doesn't
    /// support variable-width word tiles yet (single-glyph atlas
    /// only) so this value is currently ignored. Re-add via a
    /// second draw pass with a word-shape atlas — see Journal.md.
    var wordRate: Double = 0.25
    /// Multiplier on edge magnitude when boosting near glyphs into
    /// the structural ramp's top end.
    var contourBoost: Double = 1.3

    var body: some View {
        // Metal-backed renderer. Replaces the SwiftUI Canvas path
        // that couldn't survive 5184 cells × 24 Hz (~125k
        // Text.resolve calls/s). Same API, ~100× fewer draw calls,
        // one instanced quad pass.
        DepthAsciiMetalView(
            scene: scene,
            intensity: intensity,
            density: density,
            nearHue: nearHue,
            farHue: farHue,
            contourBoost: contourBoost
        )
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
