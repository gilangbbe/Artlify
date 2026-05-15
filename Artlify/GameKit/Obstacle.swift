//
//  Obstacle.swift
//  Artlify / GameKit
//
//  Value types for the three obstacle/collectible kinds plus the
//  spawner that drip-feeds them into the game world.
//
//  All positions are in screen UV (top-left origin, 0…1):
//    x = left edge of obstacle, moves leftward each tick
//    y = top  edge of obstacle, fixed for its lifetime
//

import Foundation
import CoreGraphics

enum ObstacleKind { case rock, meteor, starDust }

struct GameObstacle: Identifiable {
    let id        = UUID()
    let kind      : ObstacleKind
    var x         : Float     // left edge, screen UV — decremented each tick
    let y         : Float     // top  edge, screen UV (0 = top, 1 = bottom)
    let w         : Float     // width  (UV)
    let h         : Float     // height (UV)
    let speed     : Float     // base units/second before difficulty multiplier
    /// True once CollisionSystem has processed this obstacle (hit or collected).
    var consumed  : Bool = false

    var center: SIMD2<Float> { SIMD2(x + w / 2, y + h / 2) }

    var rect: CGRect {
        CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }
}

// MARK: - Spawner

struct ObstacleSpawner {

    private var rockTimer   : Double = 1.2   // initial delay before first rock
    private var meteorTimer : Double = 2.5
    private var dustTimer   : Double = 4.5

    mutating func reset() {
        rockTimer   = 1.2
        meteorTimer = 2.5
        dustTimer   = 4.5
    }

    /// Advance timers by `dt` seconds and call `spawn` for each new obstacle.
    /// `speedMult` is the current difficulty multiplier (speeds scale with it;
    /// intervals narrow independently so the density rises faster than speed).
    mutating func tick(dt: Double,
                       elapsed: Double,
                       speedMult: Double,
                       spawn: (GameObstacle) -> Void) {
        // Interval shrinks 10 % every 15 s, floored at 45 % of original.
        let diffFactor = max(0.45, 1.0 - floor(elapsed / 15.0) * 0.10)

        // ---- Rocks (ground zone, Y 0.78…0.88) — spawn off the left edge
        rockTimer -= dt
        if rockTimer <= 0 {
            let large = Double.random(in: 0...1) < 0.25
            spawn(GameObstacle(
                kind:  .rock,
                x:     -0.10,
                y:     Float.random(in: 0.78...0.88),
                w:     large ? 0.07 : 0.04,
                h:     large ? 0.10 : 0.07,
                speed: Float(large ? 0.22 : 0.28)
            ))
            rockTimer = Double.random(in: 1.8...3.2) * diffFactor
        }

        // ---- Meteors (mid / high zone, Y 0.15…0.58) — spawn off the left edge
        meteorTimer -= dt
        if meteorTimer <= 0 {
            let high  = Double.random(in: 0...1) < 0.45
            // Randomise height only — width stays fixed so the streak reads consistently.
            let h = Float.random(in: 0.022...0.075)
            spawn(GameObstacle(
                kind:  .meteor,
                x:     -0.10,
                y:     high ? Float.random(in: 0.15...0.35) : Float.random(in: 0.35...0.58),
                w:     0.09,
                h:     h,
                speed: Float(high ? 0.55 : 0.35)
            ))
            meteorTimer = Double.random(in: 2.5...4.2) * diffFactor
        }

        // ---- Star-dust (mid zone, Y 0.25…0.55) — spawn off the left edge
        dustTimer -= dt
        if dustTimer <= 0 {
            spawn(GameObstacle(
                kind:  .starDust,
                x:     -0.10,
                y:     Float.random(in: 0.25...0.55),
                w:     0.04,
                h:     0.04,
                speed: 0.25
            ))
            dustTimer = Double.random(in: 4.0...7.0) * diffFactor
        }
    }
}
