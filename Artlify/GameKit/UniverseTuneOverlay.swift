//
//  UniverseTuneOverlay.swift
//  Artlify / GameKit — universe-tune branch
//
//  SwiftUI Canvas overlay that draws the falling tile game on top of
//  the existing camera / particle / blob-box layers.  Repainted at
//  60 Hz by an internal timer, same pattern as BlobBoxesOverlay.
//
//  Visual language: matches the project's tracker/telemetry aesthetic —
//  glowing rectangles with corner-bracket ticks, per-lane neon colours,
//  the same two-stroke glow layering used by BlobBoxes.
//

import SwiftUI
import Combine

struct UniverseTuneOverlay: View {
    let engine: TileEngine
    var onRestart: () -> Void = {}
    var onExit:    () -> Void = {}

    private let timer = Timer.publish(every: 1.0 / 60.0,
                                      on: .main, in: .common).autoconnect()
    @State private var now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    var body: some View {
        ZStack(alignment: .top) {
            Canvas { ctx, size in
                let _ = now   // captures now so timer forces redraws
                drawLaneDividers(ctx: ctx, size: size)
                drawTiles(ctx: ctx, size: size)
            }
            .allowsHitTesting(false)
            .drawingGroup()

            // Counter-mirror: the parent ZStack has scaleEffect(x:-1),
            // so apply the inverse here to keep text readable.
            if engine.isSongComplete {
                songCompleteScreen
                    .scaleEffect(x: -1, y: 1)
            } else if engine.isGameOver {
                gameOverScreen
                    .scaleEffect(x: -1, y: 1)
            } else {
                scoreHUD
                    .scaleEffect(x: -1, y: 1)
            }
        }
        .onReceive(timer) { _ in now = CFAbsoluteTimeGetCurrent() }
    }

    // MARK: - Lane dividers

    private func drawLaneDividers(ctx: GraphicsContext, size: CGSize) {
        let laneW = size.width / 4
        for i in 1..<4 {
            var p = Path()
            let x = laneW * CGFloat(i)
            p.move(to:    CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(.white.opacity(0.10)), lineWidth: 1)
        }
        // Faint lane-column backgrounds so the playing field reads clearly
        for lane in 0..<4 {
            let color = engine.song.laneColors[lane]
            let x = laneW * CGFloat(lane)
            ctx.fill(Path(CGRect(x: x, y: 0, width: laneW, height: size.height)),
                     with: .color(color.opacity(0.025)))
        }
    }

    // MARK: - Hit zone indicator

    private func drawHitZoneLine(ctx: GraphicsContext, size: CGSize) {
        let y = CGFloat(engine.hitZoneY) * size.height
        var p = Path()
        p.move(to:    CGPoint(x: 0, y: y))
        p.addLine(to: CGPoint(x: size.width, y: y))
        ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 8)
        ctx.stroke(p, with: .color(.white.opacity(0.28)), lineWidth: 1)
    }

    // MARK: - Tiles

    private func drawTiles(ctx: GraphicsContext, size: CGSize) {
        let laneW = size.width / 4
        let st    = engine.songTime

        for tile in engine.activeTiles {
            let topY   = engine.tileTopY(tile)
            let height = engine.tileHeight(tile)

            // Early-out: completely off screen
            guard topY < 1.1 && topY + height > -0.05 else { continue }

            let color = engine.song.laneColors[tile.lane]
            let rect = CGRect(
                x:      CGFloat(tile.lane) * laneW + 3,
                y:      CGFloat(topY)      * size.height,
                width:  laneW - 6,
                height: CGFloat(height)    * size.height
            )

            switch tile.state {
            case .active:
                // Brightness ramps up as tile approaches hitZoneY
                let dist   = abs(topY - engine.hitZoneY)
                let bright = CGFloat(max(0.35, 1.0 - dist * 1.3))
                let seed = tile.lane * 1000 + Int(tile.absoluteTargetTime * 100)
                drawActiveTile(rect: rect, lane: tile.lane, color: color,
                               bright: bright, now: now, seed: seed, ctx: ctx)

            case .hit:
                let age   = st - (tile.hitTime ?? st)
                let alpha = CGFloat(max(0.0, 1.0 - age / 0.50))
                drawHitFlash(rect: rect, color: color, alpha: alpha, ctx: ctx)

            case .missed:
                let age   = st - (tile.missedTime ?? st)
                let alpha = CGFloat(max(0.0, 1.0 - age / 0.65))
                drawMissedTile(rect: rect, alpha: alpha, ctx: ctx)
            }
        }
    }

    // MARK: - Tile draw helpers

    private func drawActiveTile(rect: CGRect, lane: Int, color: Color, bright: CGFloat,
                                now: Double, seed: Int, ctx: GraphicsContext) {
        let path = wavyTileShape(rect, now: now, seed: seed)

        // Base fill + glow — same two-layer style as before.
        ctx.fill(path, with: .color(color.opacity(0.12 * bright)))
        ctx.fill(path, with: .color(color.opacity(0.28 * bright)))
        ctx.stroke(path, with: .color(color.opacity(0.22 * bright)), lineWidth: 6)
        ctx.stroke(path, with: .color(color.opacity(0.90 * bright)), lineWidth: 1.5)

        // Fire gradient: yellow-white core → orange → red → transparent,
        // covering the top 40 % of the tile. Flickers with time.
        let fireH   = min(rect.height * 0.42, 34.0)
        let flicker = CGFloat(0.80 + 0.20 * sin(now * 9.7 + Double(seed) * 1.9))
        ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY,
                              width: rect.width, height: fireH)),
                 with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.97, blue: 0.72)
                                .opacity(0.92 * bright * flicker),  location: 0.00),
                        .init(color: Color(red: 1.0, green: 0.58, blue: 0.08)
                                .opacity(0.78 * bright * flicker),  location: 0.30),
                        .init(color: Color(red: 0.88, green: 0.12, blue: 0.02)
                                .opacity(0.42 * bright * flicker),  location: 0.68),
                        .init(color: color.opacity(0),               location: 1.00),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint:   CGPoint(x: rect.midX, y: rect.minY + fireH)
                 ))

        // Warm corona extending above the tile top — the heat haze / glow.
        let coronaH = fireH * 0.75
        ctx.fill(Path(CGRect(x: rect.minX - 4, y: rect.minY - coronaH,
                              width: rect.width + 8, height: coronaH)),
                 with: .linearGradient(
                    Gradient(colors: [
                        .clear,
                        Color(red: 1.0, green: 0.45, blue: 0.05).opacity(0.18 * bright * flicker),
                        Color(red: 1.0, green: 0.70, blue: 0.15).opacity(0.50 * bright * flicker),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY - coronaH),
                    endPoint:   CGPoint(x: rect.midX, y: rect.minY)
                 ))

        // Embers: 4 small sparks that pulse and drift upward from the fire zone.
        let embers: [(xf: CGFloat, freq: Double, ph: Double)] = [
            (0.18, 6.3, 0.0), (0.44, 8.5, 1.7), (0.67, 7.1, 3.1), (0.84, 5.8, 2.3),
        ]
        for e in embers {
            let ex     = rect.minX + e.xf * rect.width
            let drift  = CGFloat(now * 16.0).truncatingRemainder(dividingBy: fireH + coronaH)
            let ey     = rect.minY + fireH * 0.3 - drift
            guard ey >= rect.minY - coronaH - 2 else { continue }
            let pulse  = CGFloat(0.50 + 0.50 * sin(now * e.freq + Double(seed) + e.ph))
            let er     = CGFloat(1.3 + 0.9 * pulse)
            let orange = CGFloat(0.40 + 0.60 * pulse)
            ctx.fill(
                Path(ellipseIn: CGRect(x: ex - er, y: ey - er,
                                       width: er * 2, height: er * 2)),
                with: .color(Color(red: 1.0, green: orange, blue: 0.10)
                    .opacity(pulse * bright * 0.90))
            )
        }

        // Note label when close to hit zone.
        if bright > 0.65 {
            let names    = ["G4", "B4", "D5", "G5"]
            let resolved = ctx.resolve(
                Text(names[min(lane, 3)])
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(color.opacity(bright))
            )
            let tSize = resolved.measure(in: CGSize(width: 200, height: 40))
            ctx.draw(resolved,
                     at: CGPoint(x: rect.midX - tSize.width / 2,
                                 y: rect.midY  - tSize.height / 2),
                     anchor: .topLeading)
        }
    }

    /// Tile path: square top corners, rounded bottom corners, and subtle
    /// sine-wave undulation on the sides — most pronounced at the top
    /// (fire zone) and smoothing to straight near the rounded base.
    private func wavyTileShape(_ rect: CGRect, now: Double, seed: Int) -> Path {
        let cornerR = min(rect.width * 0.38, 10.0)
        let amp: CGFloat  = 2.6
        let freq: CGFloat = 0.16
        let phase = CGFloat(now * 2.6) + CGFloat(seed) * 0.55
        let step: CGFloat = 5.0

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        // Right side — waviness fades toward the bottom corner.
        var y = rect.minY
        while y < rect.maxY - cornerR {
            y = min(y + step, rect.maxY - cornerR)
            let fade = max(0.0, 1.0 - (y - rect.minY) / (rect.height * 0.70))
            let wave = amp * CGFloat(fade) * sin(y * freq + phase)
            p.addLine(to: CGPoint(x: rect.maxX + wave, y: y))
        }

        // Bottom-right rounded corner.
        p.addArc(center: CGPoint(x: rect.maxX - cornerR, y: rect.maxY - cornerR),
                 radius: cornerR, startAngle: .degrees(0), endAngle: .degrees(90),
                 clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + cornerR, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + cornerR, y: rect.maxY - cornerR),
                 radius: cornerR, startAngle: .degrees(90), endAngle: .degrees(180),
                 clockwise: false)

        // Left side — opposite phase so the two sides breathe independently.
        y = rect.maxY - cornerR
        while y > rect.minY {
            y = max(y - step, rect.minY)
            let fade = max(0.0, 1.0 - (y - rect.minY) / (rect.height * 0.70))
            let wave = amp * CGFloat(fade) * sin(y * freq + phase + .pi * 0.65)
            p.addLine(to: CGPoint(x: rect.minX - wave, y: y))
        }

        p.closeSubpath()
        return p
    }

    private func drawHitFlash(rect: CGRect, color: Color, alpha: CGFloat,
                              ctx: GraphicsContext) {
        // Meteor impact: expanding elliptical shock ring centred on the head
        let impact  = CGPoint(x: rect.midX, y: rect.maxY)
        let baseR   = rect.width * 0.55
        let spread  = (1.0 - alpha) * rect.width * 0.90

        // Outer expanding ring
        let outerR = baseR + spread
        let outer  = Path(ellipseIn: CGRect(x: impact.x - outerR,
                                             y: impact.y - outerR * 0.55,
                                             width: outerR * 2, height: outerR * 1.1))
        ctx.stroke(outer, with: .color(color.opacity(0.70 * alpha)), lineWidth: 2)
        ctx.stroke(outer, with: .color(.white.opacity(0.35 * alpha)), lineWidth: 1)

        // Inner fill burst
        let innerR = baseR * 0.55 + spread * 0.35
        let inner  = Path(ellipseIn: CGRect(x: impact.x - innerR,
                                             y: impact.y - innerR * 0.65,
                                             width: innerR * 2, height: innerR * 1.3))
        ctx.fill(inner, with: .color(color.opacity(0.50 * alpha)))
        ctx.fill(inner, with: .color(.white.opacity(0.30 * alpha)))

        // White-hot flash at point of impact
        let flashR = baseR * 0.20 * alpha
        ctx.fill(Path(ellipseIn: CGRect(x: impact.x - flashR, y: impact.y - flashR * 0.6,
                                         width: flashR * 2, height: flashR * 1.2)),
                 with: .color(.white.opacity(alpha)))
    }

    private func drawMissedTile(rect: CGRect, alpha: CGFloat, ctx: GraphicsContext) {
        // Burned-out meteor: dark red tapering body, dissolving downward
        let halfW = rect.width / 2
        var body  = Path()
        body.move(to:    CGPoint(x: rect.midX - 3, y: rect.minY))
        body.addLine(to: CGPoint(x: rect.midX + 3, y: rect.minY))
        body.addLine(to: CGPoint(x: rect.midX + halfW - 2, y: rect.maxY))
        body.addLine(to: CGPoint(x: rect.midX - halfW + 2, y: rect.maxY))
        body.closeSubpath()

        ctx.fill(body, with: .linearGradient(
            Gradient(colors: [.clear, Color.red.opacity(0.40 * alpha)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint:   CGPoint(x: rect.midX, y: rect.maxY)
        ))
        ctx.stroke(body, with: .color(Color.red.opacity(0.55 * alpha)), lineWidth: 1)
    }

    // MARK: - Song complete screen

    @ViewBuilder
    private var songCompleteScreen: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()

            VStack(spacing: 24) {
                Text(engine.song.title.uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .tracking(6)

                Text("PERFECT CLEAR")
                    .font(.system(size: 44, weight: .black, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .purple, .pink],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .shadow(color: .cyan.opacity(0.7), radius: 20)
                    .shadow(color: .purple.opacity(0.5), radius: 40)

                Text(engine.score.formatted())
                    .font(.system(size: 52, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan.opacity(0.9), radius: 14)

                VStack(spacing: 6) {
                    if engine.totalHits + engine.totalMisses > 0 {
                        let acc = Double(engine.totalHits) /
                                  Double(engine.totalHits + engine.totalMisses)
                        Text(String(format: "%.0f %%  accuracy", acc * 100))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Text("\(engine.totalHits) notes hit")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }

                HStack(spacing: 20) {
                    Button(action: onRestart) {
                        Label("play again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.large)

                    Button(action: onExit) {
                        Label("exit", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(48)
        }
    }

    // MARK: - Game over screen

    @ViewBuilder
    private var gameOverScreen: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("GAME OVER")
                    .font(.system(size: 48, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .red.opacity(0.85), radius: 18)
                    .shadow(color: .red.opacity(0.40), radius: 40)

                Text(engine.score.formatted())
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .cyan.opacity(0.7), radius: 10)

                if engine.totalHits + engine.totalMisses > 0 {
                    let acc = Double(engine.totalHits) /
                              Double(engine.totalHits + engine.totalMisses)
                    Text(String(format: "%.0f %%  accuracy", acc * 100))
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                HStack(spacing: 20) {
                    Button(action: onRestart) {
                        Label("restart", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)

                    Button(action: onExit) {
                        Label("exit", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(40)
        }
    }

    // MARK: - Score HUD

    @ViewBuilder
    private var scoreHUD: some View {
        VStack(spacing: 3) {
            // Song title
            Text("universe tune")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(4)

            // Score
            Text(engine.score.formatted())
                .font(.system(size: 40, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .cyan.opacity(0.8), radius: 12)

            // Combo
            if engine.combo > 2 {
                Text("× \(engine.combo)  combo")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(comboColor)
                    .shadow(color: comboColor.opacity(0.7), radius: 6)
            }

            // Accuracy line
            if engine.totalHits + engine.totalMisses > 0 {
                let acc = Double(engine.totalHits) /
                          Double(engine.totalHits + engine.totalMisses)
                Text(String(format: "%.0f %%  acc", acc * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.top, 22)
        .allowsHitTesting(false)
    }

    private var comboColor: Color {
        switch engine.combo {
        case ..<5:   return .yellow
        case ..<15:  return .orange
        default:     return .pink
        }
    }
}

