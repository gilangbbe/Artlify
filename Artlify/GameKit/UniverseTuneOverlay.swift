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
            if engine.isGameOver {
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
                drawActiveTile(rect: rect, lane: tile.lane, color: color, bright: bright, ctx: ctx)

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
                                ctx: GraphicsContext) {
        let path = Path(rect)

        // Fill layers: dim body + edge glow
        ctx.fill(path, with: .color(color.opacity(0.12 * bright)))
        ctx.fill(path, with: .color(color.opacity(0.28 * bright)))

        // Outer glow stroke
        ctx.stroke(path, with: .color(color.opacity(0.22 * bright)), lineWidth: 6)
        // Crisp inner border
        ctx.stroke(path, with: .color(color.opacity(0.90 * bright)), lineWidth: 1.5)

        // Corner tick brackets
        let tick = max(6, min(rect.width, rect.height) * 0.22)
        var ticks = Path()
        // Top-left
        ticks.move(to:    CGPoint(x: rect.minX, y: rect.minY + tick))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.minX + tick, y: rect.minY))
        // Top-right
        ticks.move(to:    CGPoint(x: rect.maxX - tick, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tick))
        // Bottom-right
        ticks.move(to:    CGPoint(x: rect.maxX, y: rect.maxY - tick))
        ticks.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.maxX - tick, y: rect.maxY))
        // Bottom-left
        ticks.move(to:    CGPoint(x: rect.minX + tick, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ticks.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tick))
        ctx.stroke(ticks, with: .color(color.opacity(bright)), lineWidth: 2)

        // Lane note name in tile when it's near the hit zone
        if bright > 0.65 {
            let names = ["G4", "B4", "D5", "G5"]
            let label = names[min(lane, 3)]
            let text  = Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(color.opacity(bright))
            let resolved = ctx.resolve(text)
            let tSize    = resolved.measure(in: CGSize(width: 200, height: 40))
            ctx.draw(resolved,
                     at: CGPoint(x: rect.midX - tSize.width / 2,
                                 y: rect.midY - tSize.height / 2),
                     anchor: .topLeading)
        }
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

