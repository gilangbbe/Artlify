//
//  AsciiDepthBackground.swift
//  Artlify / AppShell
//
//  A psychologically inverted depth field rendered as a grid of
//  monospaced ASCII glyphs. Reads as a corrupted terminal panorama
//  whose vanishing point is OUTSIDE the screen rather than at the
//  centre — the periphery feels close, the centre feels hollow,
//  and a sinusoidal scroll pulses outward so the whole environment
//  feels like it's collapsing toward the viewer instead of
//  receding behind them.
//
//  Performance: per frame we build one `String` per row (cols
//  characters) and issue a single `ctx.draw(Text)` per row. At a
//  ~22 pt cell size on a 1920×1080 canvas that's ~50 rows × ~140
//  cols → 50 text draws, ~7000 glyphs composited into a single
//  drawingGroup() pass. Comfortable on integrated GPUs.
//

import SwiftUI

/// Counter-depth ASCII background. Drop into any ZStack below the
/// foreground overlays; uses `allowsHitTesting(false)` so it never
/// intercepts gestures even at full opacity.
struct AsciiDepthBackground: View {

    /// Glyph tint hue (0…1). Phosphor cyan-ish default reads as
    /// "screen artefact" rather than warm-room ambience.
    var hue: Double = 0.55
    /// Glyph tint saturation (0…1).
    var saturation: Double = 0.65
    /// Overall opacity multiplier on the whole grid (0…1).
    var brightness: Double = 0.85
    /// Cell density (0…1). 0 = sparse big glyphs, 1 = dense small
    /// glyphs. Drives `glyphPt` inversely so the field can be tuned
    /// from "ambient texture" to "wall of text".
    var density: Double = 0.45
    /// Strength of the radial pulsation that drives the "collapsing
    /// toward viewer" effect (0…1). At 0 the depth field is a
    /// static radial gradient; at 1 the tunnel scrolls outward
    /// every frame.
    var collapse: Double = 0.75

    // Sparse → dense glyph ramp. The leading spaces keep the centre
    // of the depth field readable as "hollow" rather than crowded.
    private static let ramp: [Character] = [
        " ", " ", " ", ".", ",", ":", ";", "!", "|",
        "+", "*", "=", "#", "%", "@", "$"
    ]
    // Glitch glyphs sprinkled into the grid by the per-cell hash.
    // Mixes shaded block characters with control-language punctuation
    // so the corruption reads as both "terminal artefact" and
    // "broken codepoint".
    private static let corrupt: [Character] = [
        "\u{2592}", "\u{2588}", "\u{2593}", "/", "\\",
        "~", "^", "X", "?", "{", "}"
    ]

    var body: some View {
        // ~24 Hz repaint — fast enough that the tunnel scroll reads
        // as motion, slow enough that the per-cell glitches register
        // as discrete strobes rather than smearing into noise.
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { ctx in
            Canvas { gctx, size in
                draw(in: gctx,
                     size: size,
                     time: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
        // Composite the whole grid into a single offscreen layer so
        // SwiftUI doesn't try to diff per-glyph state every tick.
        .drawingGroup()
    }

    private func draw(in ctx: GraphicsContext,
                      size: CGSize,
                      time: TimeInterval) {
        // glyphPt → cell metrics. Monospaced advance is ~0.6× the
        // point size for the system mono; line height ~1.05×.
        let glyphPt: CGFloat = max(9, 22 - CGFloat(density) * 13)
        let cellW = glyphPt * 0.62
        let cellH = glyphPt * 1.05
        let cols = max(8, Int(size.width / cellW))
        let rows = max(8, Int(size.height / cellH))
        let font = Font.system(size: glyphPt,
                               weight: .regular,
                               design: .monospaced)

        let cx = Double(cols) * 0.5
        let cy = Double(rows) * 0.5
        let maxR = max(0.0001, sqrt(cx * cx + cy * cy))
        let t = time
        // Outward scroll. Multiplier scales with `collapse` so the
        // user can fade between "still hollow" and "rushing toward
        // the camera". The minimum floor keeps even collapse=0
        // breathing slightly so the grid never reads as a static
        // wallpaper.
        let scroll = t * (0.4 + 1.2 * collapse)
        let baseColor = Color(hue: hue, saturation: saturation, brightness: 1.0)
        let rampCount = Self.ramp.count
        let corruptCount = Self.corrupt.count
        let tHash = Int(t * 5)   // quantised time slot for the glitch hash

        // Reused per row to avoid reallocating an N-character buffer
        // once per row per frame.
        var buf: [Character] = []
        buf.reserveCapacity(cols)

        for row in 0..<rows {
            buf.removeAll(keepingCapacity: true)
            let drow = Double(row) - cy

            for col in 0..<cols {
                let dcol = Double(col) - cx
                // r ∈ [0, 1]; 0 at the dead centre, 1 at the
                // farthest corner. THIS is the inverted axis —
                // normal vanishing-point depth would use 1 - r
                // (centre = deepest = sparsest); we use r directly
                // (centre = sparse hollow, periphery = dense walls).
                let r = sqrt(dcol * dcol + drow * drow) / maxR

                // Radial sinusoid scrolling outward → glyphs cycle
                // through density bands like a tunnel rushing past.
                var d = r
                d -= sin((r * 6.0 - scroll) * .pi) * 0.22 * collapse
                // Tiny per-cell jitter so adjacent cells never lock
                // into identical glyphs even when r is identical.
                d += sin(t * 0.9
                         + Double(col) * 0.17
                         + Double(row) * 0.13) * 0.04
                d = max(0, min(0.9999, d))

                // Cheap deterministic per-cell-per-time-slot hash.
                let h = Self.hash01(col, row, tHash)
                if h > 0.992 {
                    // Glitch flash: substitute a corrupt glyph.
                    let idx = Int(h * 9973) % corruptCount
                    buf.append(Self.corrupt[idx])
                } else {
                    let idx = Int(d * Double(rampCount - 1))
                    buf.append(Self.ramp[idx])
                }
            }

            // Row-axis brightness double-encodes depth: rows near
            // the vertical centre dim out (hollow throat of the
            // tunnel), top/bottom rows light up (rushing edges).
            let rowR = abs(Double(row) - cy) / max(cy, 1)
            let opa = 0.30 + 0.70 * rowR

            let line = String(buf)
            let text = Text(line)
                .font(font)
                .foregroundColor(baseColor.opacity(opa * brightness))
            ctx.draw(
                text,
                at: CGPoint(x: 0, y: CGFloat(row) * cellH),
                anchor: .topLeading
            )
        }

        // Occasional full-width horizontal scanline glitch — a
        // single bright row gets a faint white wash so the field
        // reads as "screen tearing" once per ~140 ms.
        let glitchSlot = floor(t * 7)
        let g = Self.hash01(Int(glitchSlot), 0, 0)
        if g > 0.55 {
            let glitchRow = Int(g * Double(rows)) % rows
            let rect = CGRect(x: 0,
                              y: CGFloat(glitchRow) * cellH,
                              width: size.width,
                              height: cellH)
            ctx.fill(Path(rect),
                     with: .color(.white.opacity(0.06 * brightness)))
        }
    }

    /// 64-bit FNV-1a → uniform [0,1). Deterministic given the same
    /// (col, row, time-slot) triple, so glitches stay coherent for
    /// the duration of one ~0.2 s slot instead of strobing every
    /// repaint.
    private static func hash01(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for v in [a, b, c] {
            h ^= UInt64(bitPattern: Int64(v))
            h = h &* 0x100000001b3
        }
        return Double(h % 10_000) / 10_000.0
    }
}
