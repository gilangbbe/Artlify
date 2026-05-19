//
//  HandOpen.swift
//  Artlify / VisionKit
//
//  Open-hand gesture detector. Replaces the earlier "filmmaker frame"
//  L-shape detector — that gesture turned out to be unreliable in
//  installation lighting and required bimanual commitment. The open
//  palm is far more legible: one or two hands, visitors do it
//  reflexively when they want to "show", and it gives a sharp on/off
//  signal that's perfect for triggering a full-screen flash effect.
//
//  Detection contract:
//    * At least one hand detected by Vision.
//    * On that hand, the four non-thumb fingertips (index, middle,
//      ring, little) sit far enough from the wrist relative to their
//      MCP joints to count as "extended" rather than "curled into
//      fist".
//    * Openness score = average extension ratio across the four
//      fingers. 1.0 = tips at MCPs (closed); >1.7 ≈ open palm.
//
//  Output is in Vision-normalised coordinates (origin bottom-left,
//  y up, 0…1). The whole module is pure / nonisolated / Sendable so
//  it can run inside the VisionProcessor actor without isolation
//  warnings.
//

import Foundation
import CoreGraphics

/// Distilled hand landmarks the open-hand detector needs.
/// Optional members because Vision returns per-landmark confidences
/// and any of these can be missing on a partially-occluded hand.
nonisolated public struct HandObservation: Sendable {
    public enum Chirality: Sendable { case left, right, unknown }

    public let chirality: Chirality
    public let wrist: CGPoint?
    /// Index / middle / ring / little fingertips (skip thumb — its
    /// geometry doesn't fit the "extension ratio" model cleanly).
    public let tips: [CGPoint?]   // size 4: [index, middle, ring, little]
    /// MCP (metacarpophalangeal — knuckle) for each of those four
    /// fingers, same order. Used as the per-finger baseline so the
    /// detector is invariant to hand size, distance from camera and
    /// rotation.
    public let mcps: [CGPoint?]   // size 4
    /// Mean confidence of the landmarks above.
    public let confidence: Float

    public init(chirality: Chirality,
                wrist: CGPoint?,
                tips: [CGPoint?],
                mcps: [CGPoint?],
                confidence: Float) {
        self.chirality = chirality
        self.wrist = wrist
        self.tips = tips
        self.mcps = mcps
        self.confidence = confidence
    }
}

/// Result of an open-hand detection pass.
nonisolated public struct HandOpenInfo: Sendable {
    /// 0…1 monotonic openness score. >= `HandOpenDetector.threshold`
    /// is the "open" verdict; the raw score is still exposed so the
    /// driver can drive smooth envelopes or hysteresis.
    public let openness: Float
    /// Centroid of the detected palm (mean of wrist + tips), in
    /// Vision-normalised coords. Useful if the visual effect ever
    /// wants to anchor on the hand instead of flashing the whole
    /// frame.
    public let center: CGPoint
    /// Chirality of the hand that scored highest.
    public let chirality: HandObservation.Chirality

    public init(openness: Float, center: CGPoint,
                chirality: HandObservation.Chirality) {
        self.openness = openness
        self.center = center
        self.chirality = chirality
    }
}

/// Pure detector. Returns the open-hand summary for the most-open
/// hand in the input, or nil if none crosses the gate.
nonisolated public enum HandOpenDetector {

    /// Mean extension ratio above which a hand counts as "open".
    /// Closed fist ≈ 1.0; pointing index only ≈ 1.2; full open palm
    /// typically lands in 1.8–2.4. 1.55 gives a comfortable margin
    /// from accidental triggers while still firing on a casual wave.
    public static let threshold: Float = 1.55
    /// Minimum mean landmark confidence; below this the hand reading
    /// is too noisy to trust.
    public static let minConfidence: Float = 0.35

    public static func detect(_ hands: [HandObservation]) -> HandOpenInfo? {
        var best: HandOpenInfo? = nil
        for h in hands {
            guard h.confidence >= minConfidence else { continue }
            guard let info = score(h) else { continue }
            if info.openness < threshold { continue }
            if best == nil || info.openness > best!.openness {
                best = info
            }
        }
        return best
    }

    /// Compute the openness score for a single hand. Returns nil if
    /// there aren't enough landmarks to compute even a partial mean.
    private static func score(_ h: HandObservation) -> HandOpenInfo? {
        guard let wrist = h.wrist else { return nil }
        var ratios: [CGFloat] = []
        ratios.reserveCapacity(4)
        var centroidX = wrist.x
        var centroidY = wrist.y
        var nCentroid = 1
        for i in 0..<4 {
            guard let tip = h.tips[i], let mcp = h.mcps[i] else { continue }
            let dTip = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let dMcp = hypot(mcp.x - wrist.x, mcp.y - wrist.y)
            // MCP is the knuckle, ~half the hand length out from
            // the wrist. Avoid the divide-by-zero on a degenerate
            // observation (extremely-foreshortened hand).
            guard dMcp > 0.005 else { continue }
            ratios.append(dTip / dMcp)
            centroidX += tip.x
            centroidY += tip.y
            nCentroid += 1
        }
        // Require at least 3 of the 4 fingers to have both tip + MCP
        // confidently tracked — anything less and the mean is noise.
        guard ratios.count >= 3 else { return nil }
        let mean = ratios.reduce(0, +) / CGFloat(ratios.count)
        let center = CGPoint(x: centroidX / CGFloat(nCentroid),
                             y: centroidY / CGFloat(nCentroid))
        return HandOpenInfo(openness: Float(mean),
                            center: center,
                            chirality: h.chirality)
    }
}
