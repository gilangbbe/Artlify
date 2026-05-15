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

    // Single unified countdown. When it fires the screen is clear and a
    // random obstacle type is chosen — guaranteeing variety and exactly
    // one object on screen at a time.
    private var nextTimer: Double = 1.5

    mutating func reset() {
        nextTimer = 1.5
    }

    mutating func tick(dt: Double,
                       elapsed: Double,
                       speedMult: Double,
                       hasObstacle: Bool,
                       spawn: (GameObstacle) -> Void) {
        nextTimer -= dt
        guard nextTimer <= 0 && !hasObstacle else { return }

        // Interval shrinks 10 % every 15 s, floored at 45 % of original.
        let diffFactor = max(0.45, 1.0 - floor(elapsed / 15.0) * 0.10)

        // 40 % rock · 40 % meteor · 20 % star-dust
        let roll = Double.random(in: 0..<1)

        if roll < 0.40 {
            // ---- Rock (ground)
            let large = Double.random(in: 0..<1) < 0.25
            let rockH : Float = large ? 0.055 : 0.038
            spawn(GameObstacle(
                kind:  .rock,
                x:     -0.10,
                y:     1.0 - rockH,
                w:     large ? 0.04 : 0.025,
                h:     rockH,
                speed: Float(large ? 0.12 : 0.15)
            ))
            nextTimer = Double.random(in: 1.8...3.2) * diffFactor

        } else if roll < 0.80 {
            // ---- Meteor (midair)
            let high = Double.random(in: 0..<1) < 0.45
            let h    = Float.random(in: 0.022...0.075)
            spawn(GameObstacle(
                kind:  .meteor,
                x:     -0.10,
                y:     high ? Float.random(in: 0.15...0.35) : Float.random(in: 0.35...0.58),
                w:     0.09,
                h:     h,
                speed: Float(high ? 0.28 : 0.18)
            ))
            nextTimer = Double.random(in: 2.5...4.2) * diffFactor

        } else {
            // ---- Star-dust (collectible)
            spawn(GameObstacle(
                kind:  .starDust,
                x:     -0.10,
                y:     Float.random(in: 0.25...0.55),
                w:     0.04,
                h:     0.04,
                speed: 0.13
            ))
            nextTimer = Double.random(in: 4.0...7.0) * diffFactor
        }
    }
}
