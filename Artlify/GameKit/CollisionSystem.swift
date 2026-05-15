//
//  CollisionSystem.swift
//  Artlify / GameKit
//
//  Hybrid collision model:
//
//  Rocks (ground, y ≈ 0.96)
//    Camera rarely captures feet, so mask sampling at mv ≈ 0.04 returns
//    nothing. Instead: hit fires if the rock's x overlaps the player's
//    body x-band AND the player has not jumped.
//
//  Meteors / Star-dust (midair, y 0.15 … 0.58)
//    These are at torso/head height — well-covered by the segmentation
//    mask. Primary: 3×3 pixel sampling inside the inner 70 % of the
//    obstacle rect, ≥ 2 samples > 128 required.
//    Fallback (mask nil): body x-band overlap + state check.
//
//  Coordinate spaces:
//    Obstacle rect : screen UV top-left origin (x 0…1, y 0…1, y=0 top)
//    personMask    : Vision UV bottom-left origin → flip Y (mv = 1 − v)
//

import Foundation
import CoreVideo
import CoreGraphics

enum CollisionEventKind { case hit, collected }

struct CollisionEvent {
    let kind         : CollisionEventKind
    let center       : SIMD2<Float>
    let obstacleKind : ObstacleKind
}

struct CollisionSystem {

    static func resolve(obstacles : inout [GameObstacle],
                        mask      : CVPixelBuffer?,
                        bodyRect  : CGRect,
                        bodyState : BodyState,
                        onEvent   : (CollisionEvent) -> Void) {
        guard !bodyRect.isEmpty else { return }

        // Body x-band used for rock and mask-fallback checks.
        let cx        = bodyRect.midX
        let halfBody  = max(bodyRect.width * 0.45, 0.06)
        let bodyMinX  = cx - halfBody
        let bodyMaxX  = cx + halfBody

        // Lock mask once for all midair checks.
        var maskLocked = false
        var maskBase: UnsafeMutableRawPointer? = nil
        var mw = 0, mh = 0, bpr = 0
        if let mask {
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            maskLocked = true
            maskBase   = CVPixelBufferGetBaseAddress(mask)
            mw  = CVPixelBufferGetWidth(mask)
            mh  = CVPixelBufferGetHeight(mask)
            bpr = CVPixelBufferGetBytesPerRow(mask)
        }
        defer { if maskLocked, let mask { CVPixelBufferUnlockBaseAddress(mask, .readOnly) } }

        for i in obstacles.indices where !obstacles[i].consumed {
            let obs = obstacles[i]
            guard obs.x < 1.0 && obs.x + obs.w > 0 else { continue }

            let obsMinX = Double(obs.x)
            let obsMaxX = Double(obs.x + obs.w)

            var triggered = false

            switch obs.kind {

            case .rock:
                // Ground obstacle — use body-state logic (feet not in camera frame).
                if obsMinX < bodyMaxX && obsMaxX > bodyMinX {
                    triggered = bodyState != .jumping
                }

            case .meteor, .starDust:
                // Midair obstacle — prefer mask, fall back to body-state.
                if let base = maskBase, mw > 0 {
                    triggered = hitsMask(obs, base: base, mw: mw, mh: mh, bpr: bpr)
                } else if obsMinX < bodyMaxX && obsMaxX > bodyMinX {
                    triggered = obs.kind == .starDust ? true : bodyState != .ducking
                }
            }

            guard triggered else { continue }
            obstacles[i].consumed = true
            let evtKind: CollisionEventKind = obs.kind == .starDust ? .collected : .hit
            onEvent(CollisionEvent(kind: evtKind, center: obs.center, obstacleKind: obs.kind))
        }
    }

    // MARK: - Mask pixel sampling (meteors / star-dust)

    /// 3×3 grid inside the inner 70 % of the obstacle rect.
    /// Returns true when ≥ 2 samples hit a person pixel (value > 128).
    private static func hitsMask(_ obs : GameObstacle,
                                 base  : UnsafeMutableRawPointer,
                                 mw    : Int,
                                 mh    : Int,
                                 bpr   : Int) -> Bool {
        let inset: Float = 0.15
        let x0 = obs.x + obs.w * inset
        let x1 = obs.x + obs.w * (1.0 - inset)
        let y0 = obs.y + obs.h * inset
        let y1 = obs.y + obs.h * (1.0 - inset)

        var hits = 0
        for gy in 0..<3 {
            for gx in 0..<3 {
                let u  = x0 + Float(gx) * (x1 - x0) / Float(2)
                let v  = y0 + Float(gy) * (y1 - y0) / Float(2)
                let mv = 1.0 - v   // flip Y: Vision mask origin is bottom-left

                let px = max(0, min(mw - 1, Int(u  * Float(mw))))
                let py = max(0, min(mh - 1, Int(mv * Float(mh))))
                let value = base.load(fromByteOffset: py * bpr + px, as: UInt8.self)
                if value > 128 { hits += 1 }
                if hits >= 2 { return true }
            }
        }
        return false
    }
}
