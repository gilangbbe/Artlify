//
//  PromptComposer.swift
//  Artlify / PromptKit
//
//  Builds the live prompt the diffusion pipeline actually sees by
//  combining:
//
//    base_prompt (from StylePreset)
//      + user_extras   (free text from the prompt field)
//      + pose_modifier (from VisionFrame, optional)
//      + motion_modifier (from VisionFrame deltas over time, optional)
//
//  Rules are intentionally simple and 100 % deterministic — no LLM,
//  no per-frame allocation surprises. See ProjectDocument.md §8.
//
//  The pose modifier inspects the joint set and adds short hints like
//  "wide gesture", "arms raised", "crouching". The motion modifier
//  measures how much the body has moved between consecutive Vision
//  frames and adds "still", "moving", or "fast motion".
//

import Foundation
import CoreGraphics

public struct PromptComposition: Equatable, Sendable {
    public let prompt: String
    public let poseHint: String?
    public let motionHint: String?
    public let suggestedStrength: Float?
}

@MainActor
public final class PromptComposer {

    public var preset: StylePreset = StylePresets.first()
    public var userExtras: String = ""
    public var enablePoseModifier: Bool = true
    public var enableMotionModifier: Bool = true

    // ---- Motion tracking
    private var lastSampleTime: CFAbsoluteTime = 0
    private var lastCentroid: CGPoint?
    private var smoothedSpeed: Double = 0   // normalized units per second, EMA

    public init() {}

    /// Build the prompt for the next diffusion call given the most recent
    /// Vision result (may be nil).
    public func compose(with frame: VisionFrame?) -> PromptComposition {
        var poseHint: String?
        var motionHint: String?

        if enablePoseModifier, let frame {
            poseHint = poseModifier(for: frame)
        }
        if enableMotionModifier, let frame {
            motionHint = motionModifier(for: frame)
        } else {
            // Decay the EMA so that toggling motion off then on doesn't
            // produce a stale reading.
            smoothedSpeed = 0
            lastCentroid = nil
        }

        var parts: [String] = [preset.basePrompt]
        let extras = userExtras.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extras.isEmpty { parts.append(extras) }
        if let poseHint { parts.append(poseHint) }
        if let motionHint { parts.append(motionHint) }

        return PromptComposition(
            prompt: parts.joined(separator: ", "),
            poseHint: poseHint,
            motionHint: motionHint,
            suggestedStrength: nil
        )
    }

    // MARK: - Modifiers

    /// Cheap rule-based pose interpretation. Vision joint names are the raw
    /// VNHumanBodyPoseObservation strings stored in `VisionJoint.id`.
    private func poseModifier(for frame: VisionFrame) -> String? {
        let byId: [String: VisionJoint] = Dictionary(
            uniqueKeysWithValues: frame.joints.map { ($0.id, $0) }
        )
        // Confidence floor: only judge a posture if we trust the joints.
        func j(_ name: String) -> VisionJoint? {
            byId[name].flatMap { $0.confidence >= 0.4 ? $0 : nil }
        }

        let lShoulder = j("left_shoulder_1_joint")
        let rShoulder = j("right_shoulder_1_joint")
        let lHand     = j("left_hand_joint")
        let rHand     = j("right_hand_joint")
        let lHip      = j("left_hip_joint")
        let rHip      = j("right_hip_joint")
        let lKnee     = j("left_leg_joint")
        let rKnee     = j("right_leg_joint")

        // Arms raised: both hands above both shoulders (Vision Y is up).
        if let lh = lHand, let rh = rHand, let ls = lShoulder, let rs = rShoulder,
           lh.point.y > ls.point.y + 0.05,
           rh.point.y > rs.point.y + 0.05 {
            return "arms raised, dynamic energetic pose"
        }

        // Wide gesture: hand-to-shoulder horizontal distance is large.
        if let lh = lHand, let rh = rHand {
            let span = abs(lh.point.x - rh.point.x)
            if span > 0.55 {
                return "wide expressive gesture, arms outstretched"
            }
        }

        // Crouching: hips noticeably below their typical position relative to knees.
        if let lh = lHip, let rh = rHip, let lk = lKnee, let rk = rKnee {
            let hipY = (lh.point.y + rh.point.y) / 2
            let kneeY = (lk.point.y + rk.point.y) / 2
            if hipY - kneeY < 0.12 {
                return "crouching low pose"
            }
        }

        return nil
    }

    /// Coarse motion hint. Computes the frame-over-frame displacement of
    /// the body centroid, scaled to a 0…1 "speed" via an EMA, and maps
    /// thresholds to "still" / "moving" / "fast motion".
    private func motionModifier(for frame: VisionFrame) -> String? {
        let now = frame.timestamp
        let centroid = bodyCentroid(frame)

        defer {
            lastSampleTime = now
            lastCentroid = centroid
        }
        guard
            let centroid,
            let last = lastCentroid,
            lastSampleTime > 0
        else {
            return nil
        }
        let dt = max(0.01, now - lastSampleTime)
        let dx = centroid.x - last.x
        let dy = centroid.y - last.y
        let dist = sqrt(Double(dx * dx + dy * dy))     // normalized units
        let speed = dist / dt                          // units / second

        // EMA, alpha = 0.4 (bias toward recent motion so the prompt
        // responds within a single diffusion cycle).
        if smoothedSpeed == 0 {
            smoothedSpeed = speed
        } else {
            smoothedSpeed = 0.6 * smoothedSpeed + 0.4 * speed
        }

        switch smoothedSpeed {
        case ..<0.05:  return "still calm pose"
        case ..<0.20:  return "gentle motion"
        default:       return "fast dynamic motion, motion blur"
        }
    }

    private func bodyCentroid(_ frame: VisionFrame) -> CGPoint? {
        let high = frame.joints.filter { $0.confidence >= 0.4 }
        guard !high.isEmpty else { return nil }
        let sx = high.reduce(0.0) { $0 + Double($1.point.x) }
        let sy = high.reduce(0.0) { $0 + Double($1.point.y) }
        let n = Double(high.count)
        return CGPoint(x: sx / n, y: sy / n)
    }
}
