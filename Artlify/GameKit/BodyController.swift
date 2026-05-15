//
//  BodyController.swift
//  Artlify / GameKit
//
//  Reads Vision body-pose joints every frame and emits a discrete
//  BodyState (standing / jumping / ducking) plus a normalized
//  bounding rect for the player's silhouette in screen UV space
//  (top-left origin, 0…1).
//
//  Jump detection: anchors on the root (pelvis) joint, falls back to
//  the average of both hip joints. A significant upward delta in Vision
//  Y (bottom-left origin, so higher Y = higher on screen) triggers a
//  jump; returning near baseline resets to standing. Duck detection is
//  the mirror: hips dropping below baseline = ducking.
//
//  The baseline drifts slowly via EMA only while the player is standing
//  so that a sustained jump or crouch doesn't recalibrate mid-gesture.
//

import Foundation
import CoreGraphics

enum BodyState: Equatable { case standing, jumping, ducking }

@MainActor
final class BodyController {

    private(set) var state: BodyState = .standing
    /// Player bounding rect in screen UV (top-left origin).
    /// Updated every Vision frame from confident joints.
    private(set) var bodyRect: CGRect = .zero

    // Detection thresholds in normalized Vision Y (0…1, bottom-left).
    private let jumpThreshold: Float  = 0.08
    private let duckThreshold: Float  = 0.06
    private let restoreMargin: Float  = 0.03
    private let baselineAlpha: Float  = 0.04   // very slow EMA — one full drift takes ~25 frames

    private var hipBaseline: Float = -1        // negative = not yet calibrated

    // MARK: - Public

    func update(frame: VisionFrame) {
        updateBodyRect(from: frame.joints)
        updateState(from: frame.joints)
    }

    func reset() {
        state = .standing
        hipBaseline = -1
        bodyRect = .zero
    }

    // MARK: - Private

    private func updateState(from joints: [VisionJoint]) {
        let anchorY = anchorHipY(from: joints)
        guard let hipY = anchorY else { return }

        if hipBaseline < 0 {
            hipBaseline = hipY   // first calibration
            return
        }

        // Vision Y is bottom-left → positive delta = moved UP on screen.
        let delta = hipY - hipBaseline

        switch state {
        case .standing:
            if delta > jumpThreshold {
                state = .jumping
            } else if delta < -duckThreshold {
                state = .ducking
            } else {
                hipBaseline = hipBaseline * (1 - baselineAlpha) + hipY * baselineAlpha
            }
        case .jumping:
            if delta < restoreMargin { state = .standing }
        case .ducking:
            if delta > -restoreMargin { state = .standing }
        }
    }

    /// Prefer `root_joint` (pelvis centre); fall back to average of hip joints.
    private func anchorHipY(from joints: [VisionJoint]) -> Float? {
        if let root = joints.first(where: { $0.id.contains("root") && $0.confidence >= 0.3 }) {
            return Float(root.point.y)
        }
        let hips = joints.filter {
            ($0.id.contains("left_hip") || $0.id.contains("right_hip")) && $0.confidence >= 0.3
        }
        guard !hips.isEmpty else { return nil }
        return Float(hips.map(\.point.y).reduce(0, +)) / Float(hips.count)
    }

    private func updateBodyRect(from joints: [VisionJoint]) {
        let confident = joints.filter { $0.confidence >= 0.3 }
        guard !confident.isEmpty else { return }

        // Vision: x = left→right, y = bottom→top.
        // Screen UV: x = same, y = top→bottom (flip y).
        var minX =  Float.infinity, maxX = -Float.infinity
        var minY =  Float.infinity, maxY = -Float.infinity

        for j in confident {
            let sx = Float(j.point.x)
            let sy = 1.0 - Float(j.point.y)
            minX = min(minX, sx); maxX = max(maxX, sx)
            minY = min(minY, sy); maxY = max(maxY, sy)
        }

        // Small margin so collision doesn't feel pixel-perfect harsh.
        let mx: Float = 0.02, my: Float = 0.02
        bodyRect = CGRect(
            x: Double(max(0, minX - mx)),
            y: Double(max(0, minY - my)),
            width:  Double(min(1, maxX + mx) - max(0, minX - mx)),
            height: Double(min(1, maxY + my) - max(0, minY - my))
        )
    }
}
