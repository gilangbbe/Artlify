//
//  CollisionSystem.swift
//  Artlify / GameKit
//
//  Collision using the Vision person-segmentation mask (personMask).
//  Samples a 3×3 grid of pixels inside each obstacle's bounding rect.
//  Any sample > 128 (person pixel) = collision.
//
//  Coordinate transform:
//    Obstacle rect : screen UV, top-left origin  (x 0…1, y 0…1, y=0 is top)
//    personMask    : Vision UV, bottom-left origin (x 0…1, y 0…1, y=0 is bottom)
//    → flip Y:  mask_y = 1.0 - screen_y
//
//  Falls back to body-bounding-rect zone logic when the mask is nil
//  (e.g. no person detected, or camera not yet running).
//

import Foundation
import CoreVideo
import CoreGraphics

enum CollisionEventKind { case hit, collected }

struct CollisionEvent {
    let kind   : CollisionEventKind
    let center : SIMD2<Float>
}

struct CollisionSystem {

    static func resolve(obstacles : inout [GameObstacle],
                        mask      : CVPixelBuffer?,
                        bodyRect  : CGRect,
                        onEvent   : (CollisionEvent) -> Void) {
        if let mask {
            resolveWithMask(&obstacles, mask: mask, onEvent: onEvent)
        } else {
            resolveWithRect(&obstacles, bodyRect: bodyRect, onEvent: onEvent)
        }
    }

    // MARK: - Mask pixel sampling

    private static func resolveWithMask(_ obstacles : inout [GameObstacle],
                                        mask        : CVPixelBuffer,
                                        onEvent     : (CollisionEvent) -> Void) {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(mask) else { return }
        let mw  = CVPixelBufferGetWidth(mask)
        let mh  = CVPixelBufferGetHeight(mask)
        let bpr = CVPixelBufferGetBytesPerRow(mask)

        for i in obstacles.indices where !obstacles[i].consumed {
            let obs = obstacles[i]
            // Only test obstacles that are crossing the visible area.
            guard obs.x < 1.0 && obs.x + obs.w > 0 else { continue }

            if hitsMask(obs, base: base, mw: mw, mh: mh, bpr: bpr) {
                obstacles[i].consumed = true
                let kind: CollisionEventKind = obs.kind == .starDust ? .collected : .hit
                onEvent(CollisionEvent(kind: kind, center: obs.center))
            }
        }
    }

    /// Sample a 3×3 grid inside the obstacle rect. Returns true if any
    /// sample lands on a person pixel (value > 128).
    private static func hitsMask(_ obs : GameObstacle,
                                 base  : UnsafeMutableRawPointer,
                                 mw    : Int,
                                 mh    : Int,
                                 bpr   : Int) -> Bool {
        let x0 = obs.x, x1 = obs.x + obs.w
        let y0 = obs.y, y1 = obs.y + obs.h   // screen UV, y=0 top

        for gy in 0..<3 {
            for gx in 0..<3 {
                let u = x0 + Float(gx) * (x1 - x0) / Float(2)   // screen UV x
                let v = y0 + Float(gy) * (y1 - y0) / Float(2)   // screen UV y (0=top)
                // Flip Y: Vision mask origin is bottom-left.
                let mu = u
                let mv = 1.0 - v

                let px = max(0, min(mw - 1, Int(mu * Float(mw))))
                let py = max(0, min(mh - 1, Int(mv * Float(mh))))
                let value = base.load(fromByteOffset: py * bpr + px, as: UInt8.self)
                if value > 128 { return true }
            }
        }
        return false
    }

    // MARK: - Fallback: body bounding-rect zones

    private static func resolveWithRect(_ obstacles : inout [GameObstacle],
                                        bodyRect    : CGRect,
                                        onEvent     : (CollisionEvent) -> Void) {
        guard !bodyRect.isEmpty else { return }

        let footZone = CGRect(x: bodyRect.minX,
                              y: bodyRect.maxY - bodyRect.height * 0.30,
                              width: bodyRect.width,
                              height: bodyRect.height * 0.30)
        let upperZone = CGRect(x: bodyRect.minX,
                               y: bodyRect.minY,
                               width: bodyRect.width,
                               height: bodyRect.height * 0.45)

        for i in obstacles.indices where !obstacles[i].consumed {
            let obs = obstacles[i]
            guard obs.x < 1.0 && obs.x + obs.w > 0 else { continue }

            let testRect: CGRect
            switch obs.kind {
            case .rock:     testRect = footZone
            case .meteor:   testRect = upperZone
            case .starDust: testRect = bodyRect
            }

            guard obs.rect.intersects(testRect) else { continue }
            obstacles[i].consumed = true
            let kind: CollisionEventKind = obs.kind == .starDust ? .collected : .hit
            onEvent(CollisionEvent(kind: kind, center: obs.center))
        }
    }
}
