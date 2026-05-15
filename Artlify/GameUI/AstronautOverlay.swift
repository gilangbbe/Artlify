//
//  AstronautOverlay.swift
//  Artlify / GameUI
//
//  Draws game objects using the same visual language as BlobBoxesOverlay:
//  double-stroke (wide soft glow + 1 px crisp line), corner tick brackets,
//  and monospaced telemetry labels underneath. No opaque fills — all shapes
//  are outlined overlays so the camera feed and particle field show through.
//
//  Colour palette:
//    Rock     — red-danger  (hue 0.00)
//    Meteor   — hot-orange  (hue 0.07)
//    StarDust — app-cyan    (hue 0.50)
//    Ground   — app-cyan    (same as status HUD accents)
//

import SwiftUI

struct AstronautOverlay: View {
    let game: GameEngine

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for obs in game.obstacles where !obs.consumed {
                    switch obs.kind {
                    case .rock:     drawObstacle(obs, hue: 0.00, label: "ROCK", ctx: ctx, size: size)
                    case .meteor:   drawMeteor(obs,   ctx: ctx, size: size)
                    case .starDust: drawStarDust(obs, ctx: ctx, size: size, t: t)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - Ground line

    private func drawGround(ctx: GraphicsContext, size: CGSize) {
        let y = size.height * 0.83
        var line = Path()
        line.move(to:    CGPoint(x: 0,          y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(line, with: .color(.cyan.opacity(0.10)), lineWidth: 6)
        ctx.stroke(line, with: .color(.cyan.opacity(0.30)), lineWidth: 1)
    }

    // MARK: - Rock / generic obstacle  (tracker-box style)

    private func drawObstacle(_ obs: GameObstacle,
                              hue: Double,
                              label: String,
                              ctx: GraphicsContext,
                              size: CGSize) {
        let r   = screenRect(obs, size)
        let col = Color(hue: hue, saturation: 0.80, brightness: 1.0)

        trackerBox(r, color: col, ctx: ctx)
        telemetryLabel(label, under: r, color: col, ctx: ctx)
    }

    // MARK: - Meteor  (elongated tracker box + trailing sweep)

    private func drawMeteor(_ obs: GameObstacle, ctx: GraphicsContext, size: CGSize) {
        let r   = screenRect(obs, size)
        let col = Color(hue: 0.07, saturation: 0.90, brightness: 1.0)

        // Trailing sweep — three fading lines to the LEFT (behind the meteor).
        for i in 1...3 {
            let alpha = 0.18 / Double(i)
            let yOff  = CGFloat(i - 2) * r.height * 0.28
            var sweep = Path()
            sweep.move(to:    CGPoint(x: r.minX,                            y: r.midY + yOff))
            sweep.addLine(to: CGPoint(x: r.minX - r.width * CGFloat(4 - i), y: r.midY + yOff))
            ctx.stroke(sweep, with: .color(col.opacity(alpha)), lineWidth: 1)
        }

        // Leading bright dot on the RIGHT (direction of travel).
        let dotR = min(r.width, r.height) * 0.28
        let dot  = CGRect(x: r.maxX - dotR * 0.5,
                          y: r.midY - dotR,
                          width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dot), with: .color(col.opacity(0.90)))

        trackerBox(r, color: col, ctx: ctx)
        telemetryLabel("METEOR", under: r, color: col, ctx: ctx)
    }

    // MARK: - Star-dust  (rotating cross + tracker brackets)

    private func drawStarDust(_ obs: GameObstacle,
                              ctx: GraphicsContext,
                              size: CGSize,
                              t: Double) {
        let r      = screenRect(obs, size)
        let col    = Color(hue: 0.50, saturation: 0.60, brightness: 1.0)
        let cx     = r.midX
        let cy     = r.midY
        let radius = min(r.width, r.height) * 0.46
        let angle  = t * 0.75
        let pulse  = 0.60 + 0.40 * sin(t * 2.8)

        // Soft halo matching glow style of existing overlays.
        let haloR = radius * 2.8
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - haloR, y: cy - haloR,
                                   width: haloR * 2, height: haloR * 2)),
            with: .color(col.opacity(0.10 * pulse))
        )

        // 6-point sparkle (3 crossing stroked lines), same double-stroke approach.
        var sparkle = Path()
        for i in 0..<3 {
            let a  = angle + Double(i) * (.pi / 3.0)
            let dx = cos(a) * radius
            let dy = sin(a) * radius
            sparkle.move(to:    CGPoint(x: cx - dx, y: cy - dy))
            sparkle.addLine(to: CGPoint(x: cx + dx, y: cy + dy))
        }
        ctx.stroke(sparkle, with: .color(col.opacity(0.25 * pulse)), lineWidth: 4)
        ctx.stroke(sparkle, with: .color(col.opacity(0.90 * pulse)),
                   style: StrokeStyle(lineWidth: 1, lineCap: .round))

        trackerBox(r, color: col, ctx: ctx)
        telemetryLabel("STARDUST", under: r, color: col, ctx: ctx)
    }

    // MARK: - Shared drawing primitives (matches BlobBoxes visual language)

    /// Wide soft glow stroke + 1-px crisp stroke + corner tick brackets.
    private func trackerBox(_ r: CGRect, color: Color, ctx: GraphicsContext) {
        let path = Path(r)
        ctx.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 5)
        ctx.stroke(path, with: .color(color.opacity(0.90)), lineWidth: 1)

        let tick = max(5, min(r.width, r.height) * 0.32)
        var ticks = Path()
        // top-left
        ticks.move(to:    CGPoint(x: r.minX, y: r.minY + tick))
        ticks.addLine(to: CGPoint(x: r.minX, y: r.minY))
        ticks.addLine(to: CGPoint(x: r.minX + tick, y: r.minY))
        // top-right
        ticks.move(to:    CGPoint(x: r.maxX - tick, y: r.minY))
        ticks.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        ticks.addLine(to: CGPoint(x: r.maxX, y: r.minY + tick))
        // bottom-right
        ticks.move(to:    CGPoint(x: r.maxX, y: r.maxY - tick))
        ticks.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ticks.addLine(to: CGPoint(x: r.maxX - tick, y: r.maxY))
        // bottom-left
        ticks.move(to:    CGPoint(x: r.minX + tick, y: r.maxY))
        ticks.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        ticks.addLine(to: CGPoint(x: r.minX, y: r.maxY - tick))
        ctx.stroke(ticks, with: .color(color.opacity(0.95)), lineWidth: 2)
    }

    /// Monospaced label placed just beneath the bounding box — identical
    /// to the telemetry labels in BlobBoxesOverlay.
    private func telemetryLabel(_ text: String,
                                under r: CGRect,
                                color: Color,
                                ctx: GraphicsContext) {
        let label    = Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(color.opacity(0.85))
        let resolved = ctx.resolve(label)
        let sz       = resolved.measure(in: CGSize(width: 200, height: 20))
        let origin   = CGPoint(x: r.midX - sz.width / 2, y: r.maxY + 3)
        let plate    = Path(roundedRect:
            CGRect(x: origin.x - 3, y: origin.y - 1,
                   width: sz.width + 6, height: sz.height + 2),
            cornerRadius: 2)
        ctx.fill(plate, with: .color(.black.opacity(0.50)))
        ctx.draw(resolved, at: origin, anchor: .topLeading)
    }

    // MARK: - Helpers

    private func screenRect(_ obs: GameObstacle, _ size: CGSize) -> CGRect {
        CGRect(
            x:      Double(obs.x) * size.width,
            y:      Double(obs.y) * size.height,
            width:  Double(obs.w) * size.width,
            height: Double(obs.h) * size.height
        )
    }
}
