//
//  BlobBoxes.swift
//  Artlify / AppShell — `particles` branch
//
//  Blob-tracking overlay: each tracked body region (= one pose joint
//  used as a cheap blob proxy) gets a small bounding box that flashes
//  on/off at random, and the currently-flashing boxes are linked to
//  each other by thin "string" lines. Visually it reads as a sparse
//  technical-tracking diagram pulsing on top of the dark scene —
//  same flicker idiom as the negative-camera boxes, but as outlined
//  rectangles with connective tissue between them.
//
//  Why pose joints as blobs: Vision already gives us up to 19 stable,
//  pre-identified points at ~15 Hz. A real per-pixel blob extraction
//  off the segmentation mask (connected components, centroid tracking,
//  Hungarian-style ID matching across frames) would add CPU cost for
//  almost no visual gain — the joints already cluster on the same
//  body regions a CC pass would find.
//

import SwiftUI
import Combine

/// One tracked blob: smoothed position + per-blob style + a flash gate
/// that turns the box visible only when it's "lit".
struct BlobBox: Identifiable {
    let id: String                // joint id, stable across frames
    var center: SIMD2<Float>      // top-left uv, smoothed
    var halfSize: SIMD2<Float>    // uv-space half-extents
    let hue: Double               // stable per-id colour thread
    /// Wall-clock time this box should remain "lit" until.
    /// While `now < flashUntil` the box and its connecting strings
    /// are drawn; outside that window the slot is invisible. This is
    /// what reproduces the negative-box flicker idiom.
    var flashUntil: CFAbsoluteTime
    var lastSeen: CFAbsoluteTime
}

@Observable
final class BlobBoxStore {
    /// All tracked blobs, keyed by joint id.
    private(set) var boxes: [String: BlobBox] = [:]

    /// Drop blobs we haven't seen for this many seconds.
    var pruneAfter: TimeInterval = 0.6

    /// How long an individual flash lasts. Short enough to feel like
    /// a strobe, long enough that the connecting strings register.
    var flashDuration: TimeInterval = 0.16

    /// Per-tick probability that a given currently-tracked blob lights
    /// up. With ~9 Hz tick + ~10 blobs visible this gives a busy but
    /// not overwhelming flicker.
    var flashProbability: Double = 0.30

    /// EMA factor for centre smoothing — Vision is jittery at 15 Hz
    /// and a hard snap to each new sample makes the boxes nervous.
    var smoothing: Float = 0.55

    func clear() { boxes.removeAll() }

    /// Push the latest joint snapshot. `joints` are uv with **top-left
    /// origin** (the caller has already flipped Vision's y for us).
    func updatePositions(joints: [(id: String, uv: SIMD2<Float>)],
                         now: CFAbsoluteTime) {
        for j in joints {
            if var b = boxes[j.id] {
                b.center = Self.mix(b.center, j.uv, t: smoothing)
                b.lastSeen = now
                boxes[j.id] = b
            } else {
                // Each new blob gets a small randomised box size so
                // the overlay reads as varied trackers, not a uniform
                // grid of identical squares.
                let w = Float.random(in: 0.045...0.085)
                let h = Float.random(in: 0.045...0.085)
                boxes[j.id] = BlobBox(
                    id: j.id,
                    center: j.uv,
                    halfSize: SIMD2(w, h),
                    hue: Self.hash01(j.id),
                    flashUntil: 0,
                    lastSeen: now
                )
            }
        }
        let cutoff = now - pruneAfter
        boxes = boxes.filter { $0.value.lastSeen >= cutoff }
    }

    /// Randomly light up a fraction of currently-tracked boxes. Called
    /// from the same ~9 Hz tick as the negative-box flasher in
    /// ContentView so the rhythms cohere across the two layers.
    func tickFlash(now: CFAbsoluteTime) {
        for (id, var b) in boxes {
            // If a box is currently lit, leave it alone — re-rolling
            // every tick would clip the flash duration.
            if b.flashUntil > now { continue }
            if Double.random(in: 0...1) < flashProbability {
                b.flashUntil = now + flashDuration
                boxes[id] = b
            }
        }
    }

    private static func mix(_ a: SIMD2<Float>, _ b: SIMD2<Float>, t: Float) -> SIMD2<Float> {
        a * (1 - t) + b * t
    }

    private static func hash01(_ s: String) -> Double {
        var h: UInt64 = 1469598103934665603
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 1099511628211
        }
        return Double(h % 360) / 360.0
    }
}

// MARK: - View

struct BlobBoxesOverlay: View {
    let store: BlobBoxStore
    /// Master α/brightness multiplier from the HUD.
    var intensity: Double = 1.0
    /// Whether to draw the connecting strings between currently-lit
    /// boxes. Off looks like pure trackers; on looks like a diagram.
    var drawStrings: Bool = true

    /// Internal repaint clock so flashes animate even between Vision
    /// passes. 60 Hz so the on/off transitions look crisp rather than
    /// stepped.
    private let timer = Timer.publish(every: 1.0 / 60.0,
                                      on: .main, in: .common).autoconnect()
    @State private var nowTick: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        Canvas { ctx, size in
            // Snapshot only the currently-lit boxes — gated draw is
            // what gives the overlay its strobe character.
            let lit = store.boxes.values.filter { $0.flashUntil > nowTick }
            guard !lit.isEmpty else { return }

            // -------- Strings between lit boxes.
            // Draw FIRST so box outlines sit on top of their endpoints.
            if drawStrings && lit.count >= 2 {
                drawStringsBetween(boxes: lit, ctx: ctx, size: size)
            }

            // -------- Each lit box.
            for b in lit {
                drawBox(b, ctx: ctx, size: size)
            }
        }
        .allowsHitTesting(false)
        .drawingGroup()
        .onReceive(timer) { _ in
            nowTick = CFAbsoluteTimeGetCurrent()
        }
    }

    private func drawBox(_ b: BlobBox, ctx: GraphicsContext, size: CGSize) {
        // Triangular envelope inside the flash window so the box
        // brightens then fades rather than hard-clipping off.
        let life = max(0, b.flashUntil - nowTick) / store.flashDuration
        let env = 1.0 - abs(2.0 * life - 1.0)        // 0..1..0
        let alpha = max(0.15, env) * intensity

        let cx = CGFloat(b.center.x) * size.width
        let cy = CGFloat(b.center.y) * size.height
        let hw = CGFloat(b.halfSize.x) * size.width
        let hh = CGFloat(b.halfSize.y) * size.height
        let rect = CGRect(x: cx - hw, y: cy - hh, width: hw * 2, height: hh * 2)

        let colour = Color(hue: b.hue, saturation: 0.55, brightness: 1.0)

        // Outlined box. Two-stroke layering — wide soft glow + crisp
        // 1-px line — so the rectangle reads as glowing on the dark
        // background instead of a flat geometric outline.
        let path = Path(rect)
        ctx.stroke(path,
                   with: .color(colour.opacity(0.25 * alpha)),
                   lineWidth: 4)
        ctx.stroke(path,
                   with: .color(colour.opacity(0.95 * alpha)),
                   lineWidth: 1)

        // Tiny corner ticks make the rectangle read as a "tracker"
        // bracket rather than a plain box. Length is 18 % of the
        // shorter side, so big and small boxes both feel proportionate.
        let tick = max(4, min(hw, hh) * 0.36)
        var ticks = Path()
        // Top-left
        ticks.move(to: CGPoint(x: rect.minX, y: rect.minY + tick))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.minX + tick, y: rect.minY))
        // Top-right
        ticks.move(to: CGPoint(x: rect.maxX - tick, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tick))
        // Bottom-right
        ticks.move(to: CGPoint(x: rect.maxX, y: rect.maxY - tick))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.maxX - tick, y: rect.maxY))
        // Bottom-left
        ticks.move(to: CGPoint(x: rect.minX + tick, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tick))
        ctx.stroke(ticks,
                   with: .color(colour.opacity(alpha)),
                   lineWidth: 2)

        // Centre dot — anchors the eye to the tracked point.
        let dot = Path(ellipseIn:
            CGRect(x: cx - 1.5, y: cy - 1.5, width: 3, height: 3))
        ctx.fill(dot, with: .color(colour.opacity(alpha)))
    }

    /// Connect every lit box to every other lit box with a thin string.
    /// At ≤6 boxes lit at once that's at most ~15 segments — trivial,
    /// and the resulting web is what makes the overlay look diagrammatic.
    private func drawStringsBetween(boxes: [BlobBox],
                                    ctx: GraphicsContext,
                                    size: CGSize) {
        let arr = Array(boxes)
        var web = Path()
        for i in 0..<arr.count {
            let p1 = CGPoint(x: CGFloat(arr[i].center.x) * size.width,
                             y: CGFloat(arr[i].center.y) * size.height)
            for j in (i + 1)..<arr.count {
                let p2 = CGPoint(x: CGFloat(arr[j].center.x) * size.width,
                                 y: CGFloat(arr[j].center.y) * size.height)
                web.move(to: p1)
                web.addLine(to: p2)
            }
        }
        // White-ish strings so the colour noise from the boxes doesn't
        // dominate; subtle glow underlay keeps them visible without
        // looking laser-bright.
        ctx.stroke(web,
                   with: .color(.white.opacity(0.10 * intensity)),
                   lineWidth: 2.5)
        ctx.stroke(web,
                   with: .color(.white.opacity(0.55 * intensity)),
                   lineWidth: 0.6)
    }
}
